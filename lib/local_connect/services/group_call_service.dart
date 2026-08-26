import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/call_session.dart' show CallMediaType;
import '../models/group_call_session.dart';
import 'call_sound_service.dart';

typedef GroupCallSignalSender = Future<bool> Function(
  String peerInternalNumber,
  Map<String, dynamic> payload,
);

/// مكالمة صوتية جماعية عبر WebRTC بلا خادم وسائط (SFU): كل مشارك يفتح
/// اتصالًا مباشرًا بكل مشارك آخر (شبكة كاملة/mesh)، فيرسل صوته لهم جميعًا
/// بالتوازي. من بدأ المكالمة (المُنسِّق) يتتبّع فقط من انضمّ فعليًا (ليس
/// وسيطًا للوسائط، فقط دفتر عضوية)، ويُبلِغ كل نشِط بأي عضو جديد ينضم عبر
/// [_handleJoin]/[_handleRoster] — بدون هذا التنسيق، لا طريقة لعضوين
/// انضمّا في وقتين مختلفين ليعرفا ببعضهما ويتصلا مباشرة.
///
/// لتفادي محاولة طرفين إرسال عرض (offer) لبعضهما في آن واحد لنفس الزوج،
/// يُقرَّر مُرسِل العرض حتميًا بمقارنة الرقمين الداخليين أبجديًا (الأصغر
/// يُرسِل العرض دائمًا) — قرار متّسق من أي طرف يُحسَب، بلا حاجة لتنسيق حول
/// هذه النقطة تحديدًا.
///
/// يدعم الصوت والفيديو معًا (نفس شبكة الاتصالات المباشرة تحمل كليهما دون
/// تغيير في التنسيق)، ومشاركة شاشة تستبدل مسار الفيديو المُرسَل لكل
/// المشاركين دفعة واحدة (انظر [toggleScreenShare]).
class GroupCallService extends ChangeNotifier {
  GroupCallService({
    required GroupCallSignalSender sendSignal,
    required String Function() localInternalNumber,
    required String Function() localDisplayName,
    String? Function(String internalNumber)? contactDisplayNameFor,
  })  : _sendSignal = sendSignal,
        _localInternalNumber = localInternalNumber,
        _localDisplayName = localDisplayName,
        _contactDisplayNameFor = contactDisplayNameFor;

  final GroupCallSignalSender _sendSignal;

  /// راجع التوثيق المطابق في CallService._contactDisplayNameFor — نفس
  /// السبب والأولوية هنا: اسم جهة اتصال محفوظ محليًا يُفضَّل على الاسم الذي
  /// يدّعيه العضو نفسه عبر الشبكة.
  final String? Function(String internalNumber)? _contactDisplayNameFor;
  final String Function() _localInternalNumber;
  final String Function() _localDisplayName;

  static const Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  final CallSoundService _sound = CallSoundService();

  GroupCallSession? currentCall;
  bool isMuted = false;
  bool isCameraOff = false;
  bool isScreenSharing = false;
  bool _disposed = false;

  MediaStream? _localStream;

  /// مسار الكاميرا الأصلي، يُحفَظ جانبًا أثناء مشاركة الشاشة حتى يمكن
  /// العودة إليه عند إيقافها بدل إعادة طلب الكاميرا من جديد.
  MediaStreamTrack? _cameraTrack;
  MediaStream? _screenStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _localRendererInitialized = false;
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Set<String> _connectingTo = {};
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  final Map<String, bool> _remoteDescriptionSet = {};
  Timer? _ringTimer;
  Timer? _clearTimer;

  /// مُصيِّر فيديو مشارك مُحدَّد، أو null إن لم يتصل بعد (لا فيديو لعرضه)
  /// أو كانت المكالمة صوتية بحتة أصلًا.
  RTCVideoRenderer? remoteRendererFor(String internalNumber) => _remoteRenderers[internalNumber];

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------
  // بدء مكالمة (المُنسِّق)
  // -------------------------------------------------------------------

  /// [memberDisplayNames] الأعضاء الآخرون المدعوّون (بدون نفسي): رقم داخلي
  /// ← اسم معروض، للاستخدام الفوري في واجهة الرنين قبل أن نعرف أسماءهم من
  /// أي مصدر آخر.
  Future<void> startGroupCall({
    required String groupId,
    required String groupName,
    required Map<String, String> memberDisplayNames,
    required CallMediaType mediaType,
  }) async {
    if (currentCall != null || memberDisplayNames.isEmpty) return;

    await _ensureRenderers();
    final callId = const Uuid().v4();
    final session = GroupCallSession(
      callId: callId,
      groupId: groupId,
      groupName: groupName,
      isInitiator: true,
      mediaType: mediaType,
    );
    for (final entry in memberDisplayNames.entries) {
      session.participants[entry.key] =
          GroupCallParticipant(internalNumber: entry.key, displayName: entry.value);
    }
    currentCall = session;
    _safeNotify();

    try {
      await _ensureLocalMedia(mediaType);
    } catch (error) {
      await _endCall(reason: 'تعذّر بدء المكالمة: $error');
      return;
    }

    for (final member in memberDisplayNames.keys) {
      unawaited(_sendSignal(member, {
        'type': 'group_call_invite',
        // معرّف لإقرار التسليم (ack) — نفس معرّف المكالمة، مُستخدَم بنفس
        // الدور في كل إشارة تخص هذه المكالمة (يحتاجه بروتوكول النقل، وليس
        // له علاقة بتمييز المكالمات عن بعضها هنا).
        'id': callId,
        'groupId': groupId,
        'callId': callId,
        'groupName': groupName,
        'mediaType': mediaType.name,
        'callerDisplayName': _localDisplayName(),
        'senderInternalNumber': _localInternalNumber(),
      }));
    }

    _startRingTimeout();
    unawaited(_sound.playRingback());
  }

  /// يقبل الانضمام لمكالمة جماعية واردة جارٍ رنينها — يطلب صلاحية
  /// الميكروفون هنا فقط (وليس عند وصول الدعوة)، ثم يُبلِغ المُنسِّق أننا
  /// انضممنا، فيتولى هو ربطنا ببقية النشِطين.
  Future<void> joinCall() async {
    final call = currentCall;
    if (call == null || call.isInitiator || call.state != GroupCallState.ringing) return;
    _cancelRingTimeout();
    unawaited(_sound.stopRingtone());
    unawaited(_sound.cancelIncomingCallNotification());
    call.state = GroupCallState.active;
    _safeNotify();

    try {
      await _ensureRenderers();
      await _ensureLocalMedia(call.mediaType);
    } catch (error) {
      await _endCall(reason: 'تعذّر الانضمام: $error');
      return;
    }

    final initiatorNumber = call.participants.keys.first;
    unawaited(_sendSignal(initiatorNumber, {
      'type': 'group_call_join',
      'id': call.callId,
      'groupId': call.groupId,
      'callId': call.callId,
      'senderInternalNumber': _localInternalNumber(),
    }));
  }

  Future<void> declineCall() async {
    final call = currentCall;
    if (call == null || call.isInitiator || call.state != GroupCallState.ringing) return;
    final initiatorNumber = call.participants.keys.first;
    unawaited(_sendSignal(initiatorNumber, {
      'type': 'call_reject',
      'id': call.callId,
      'groupId': call.groupId,
      'callId': call.callId,
      'senderInternalNumber': _localInternalNumber(),
    }));
    await _endCall(reason: null, notifyOthers: false);
  }

  Future<void> endCall() => _endCall(reason: null, notifyOthers: true);

  // -------------------------------------------------------------------
  // استقبال إشارات المكالمة الجماعية (يُستدعى من AppState._handleIncomingWire)
  // -------------------------------------------------------------------

  Future<void> handleSignal(Map<String, dynamic> payload) async {
    switch (payload['type']) {
      case 'group_call_invite':
        _handleInvite(payload);
      case 'group_call_join':
        await _handleJoin(payload);
      case 'group_call_roster':
        await _handleRoster(payload);
      case 'call_offer':
        await _handlePeerOffer(payload);
      case 'call_answer':
        await _handlePeerAnswer(payload);
      case 'call_ice_candidate':
        await _handlePeerIceCandidate(payload);
      case 'call_reject':
        _handleReject(payload);
      case 'call_end':
        await _handlePeerEnd(payload);
    }
  }

  void _handleInvite(Map<String, dynamic> payload) {
    final groupId = payload['groupId'];
    final callId = payload['callId'];
    final groupName = payload['groupName'];
    final senderInternalNumber = payload['senderInternalNumber'];
    if (groupId is! String || callId is! String || groupName is! String || senderInternalNumber is! String) {
      return;
    }

    if (currentCall != null) {
      unawaited(_sendSignal(senderInternalNumber, {
        'type': 'call_reject',
        'id': callId,
        'groupId': groupId,
        'callId': callId,
        'senderInternalNumber': _localInternalNumber(),
        'reason': 'busy',
      }));
      return;
    }

    final mediaType = payload['mediaType'] == 'video' ? CallMediaType.video : CallMediaType.audio;
    final callerDisplayName = _contactDisplayNameFor?.call(senderInternalNumber) ??
        (payload['callerDisplayName'] as String?) ??
        senderInternalNumber;
    final session = GroupCallSession(
      callId: callId,
      groupId: groupId,
      groupName: groupName,
      isInitiator: false,
      mediaType: mediaType,
    );
    session.participants[senderInternalNumber] =
        GroupCallParticipant(internalNumber: senderInternalNumber, displayName: callerDisplayName)
          ..hasJoined = true;
    currentCall = session;
    _startRingTimeout();
    unawaited(_ensureRenderers());
    unawaited(_sound.playRingtone());
    unawaited(_sound.showIncomingCallNotification('مكالمة جماعية: $groupName'));
    _safeNotify();
  }

  Future<void> _handleJoin(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null || !call.isInitiator) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    if (senderInternalNumber is! String) return;

    final participant = call.participants[senderInternalNumber];
    if (participant == null || participant.hasJoined) return;
    participant.hasJoined = true;

    _cancelRingTimeout();
    if (call.state == GroupCallState.ringing) {
      call.state = GroupCallState.active;
      unawaited(_sound.stopRingback());
    }

    await _ensurePeerConnection(senderInternalNumber, call);

    final activeParticipants = [
      _localInternalNumber(),
      ...call.participants.values.where((p) => p.hasJoined).map((p) => p.internalNumber),
    ];
    for (final joined in call.participants.values.where((p) => p.hasJoined)) {
      unawaited(_sendSignal(joined.internalNumber, {
        'type': 'group_call_roster',
        'id': call.callId,
        'groupId': call.groupId,
        'callId': call.callId,
        'participants': activeParticipants,
        'senderInternalNumber': _localInternalNumber(),
      }));
    }
    _safeNotify();
  }

  Future<void> _handleRoster(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final participantsRaw = payload['participants'];
    if (participantsRaw is! List) return;

    final myNumber = _localInternalNumber();
    for (final other in participantsRaw.whereType<String>()) {
      if (other == myNumber) continue;
      call.participants.putIfAbsent(
        other,
        () => GroupCallParticipant(internalNumber: other, displayName: other)..hasJoined = true,
      );
      await _ensurePeerConnection(other, call);
    }
    _safeNotify();
  }

  Future<void> _handlePeerOffer(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    final sdp = payload['sdp'];
    if (senderInternalNumber is! String || sdp is! String) return;

    call.participants.putIfAbsent(
      senderInternalNumber,
      () => GroupCallParticipant(internalNumber: senderInternalNumber, displayName: senderInternalNumber)
        ..hasJoined = true,
    );
    // لن يُرسِل عرضًا مزدوجًا هنا — القاعدة الحتمية (أصغر رقم يُرسِل) تمنع
    // ذلك تلقائيًا: وصول عرض منه يعني أن قاعدته هو قرَّرت أن يُرسِل، وقاعدتنا
    // (نفس المقارنة من الجهة الأخرى) ستقرّر بالضرورة ألا نُرسِل نحن.
    await _ensurePeerConnection(senderInternalNumber, call);
    final pc = _peerConnections[senderInternalNumber];
    if (pc == null) return;

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescriptionSet[senderInternalNumber] = true;
    await _drainPendingCandidates(senderInternalNumber);

    final answer = await pc.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': call.mediaType == CallMediaType.video,
    });
    await pc.setLocalDescription(answer);
    unawaited(_sendSignal(senderInternalNumber, {
      'type': 'call_answer',
      'id': call.callId,
      'groupId': call.groupId,
      'callId': call.callId,
      'senderInternalNumber': _localInternalNumber(),
      'sdp': answer.sdp,
    }));
    _safeNotify();
  }

  Future<void> _handlePeerAnswer(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    final sdp = payload['sdp'];
    if (senderInternalNumber is! String || sdp is! String) return;

    final pc = _peerConnections[senderInternalNumber];
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet[senderInternalNumber] = true;
    await _drainPendingCandidates(senderInternalNumber);
  }

  Future<void> _handlePeerIceCandidate(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    final candidate = payload['candidate'];
    if (senderInternalNumber is! String || candidate is! String) return;

    final pc = _peerConnections[senderInternalNumber];
    if (pc == null) return;
    final iceCandidate =
        RTCIceCandidate(candidate, payload['sdpMid'] as String?, payload['sdpMLineIndex'] as int?);
    if (_remoteDescriptionSet[senderInternalNumber] == true) {
      await pc.addCandidate(iceCandidate);
    } else {
      _pendingCandidates.putIfAbsent(senderInternalNumber, () => []).add(iceCandidate);
    }
  }

  void _handleReject(Map<String, dynamic> payload) {
    final call = currentCall;
    if (call == null || !call.isInitiator) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    if (senderInternalNumber is! String) return;

    call.participants.remove(senderInternalNumber);
    _safeNotify();
    if (call.state == GroupCallState.ringing && call.participants.isEmpty) {
      unawaited(_endCall(reason: 'رفض الجميع المكالمة', notifyOthers: false));
    }
  }

  Future<void> _handlePeerEnd(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null) return;
    if (!_matchesCurrentCall(call, payload)) return;
    final senderInternalNumber = payload['senderInternalNumber'];
    if (senderInternalNumber is! String) return;

    await _teardownPeerConnection(senderInternalNumber);
    call.participants.remove(senderInternalNumber);
    _safeNotify();
    _checkIfCallEnded();
  }

  bool _matchesCurrentCall(GroupCallSession call, Map<String, dynamic> payload) =>
      payload['groupId'] == call.groupId && payload['callId'] == call.callId;

  // -------------------------------------------------------------------
  // اتصال WebRTC مباشر بمشارك مُحدَّد
  // -------------------------------------------------------------------

  Future<void> _ensurePeerConnection(String otherNumber, GroupCallSession call) async {
    if (_peerConnections.containsKey(otherNumber) || _connectingTo.contains(otherNumber)) return;
    // حجز فوري ومتزامن (قبل أي await) يمنع استدعاءً آخر متداخلًا (يصل عبر
    // إشارة مختلفة في نفس اللحظة تقريبًا) من إنشاء اتصال مكرَّر لنفس الطرف.
    _connectingTo.add(otherNumber);
    try {
      if (_localStream == null) {
        await _ensureLocalMedia(call.mediaType);
      }

      final pc = await createPeerConnection(_rtcConfiguration);
      _peerConnections[otherNumber] = pc;
      _remoteDescriptionSet[otherNumber] = false;
      _pendingCandidates[otherNumber] = [];

      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }

      pc.onTrack = (event) {
        if (event.track.kind != 'video' || event.streams.isEmpty) return;
        final renderer = _remoteRenderers.putIfAbsent(otherNumber, () => RTCVideoRenderer());
        unawaited(() async {
          if (renderer.textureId == null) await renderer.initialize();
          renderer.srcObject = event.streams.first;
          _safeNotify();
        }());
      };

      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        unawaited(_sendSignal(otherNumber, {
          'type': 'call_ice_candidate',
          'id': call.callId,
          'groupId': call.groupId,
          'callId': call.callId,
          'senderInternalNumber': _localInternalNumber(),
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }));
      };
      pc.onConnectionState = (state) {
        final participant = call.participants[otherNumber];
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          participant?.linkState = ParticipantLinkState.connected;
          _safeNotify();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          participant?.linkState = ParticipantLinkState.failed;
          unawaited(_teardownPeerConnection(otherNumber).then((_) {
            call.participants.remove(otherNumber);
            _safeNotify();
            _checkIfCallEnded();
          }));
        }
      };

      final shouldOffer = _localInternalNumber().compareTo(otherNumber) < 0;
      if (shouldOffer) {
        final offer = await pc.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': call.mediaType == CallMediaType.video,
        });
        await pc.setLocalDescription(offer);
        unawaited(_sendSignal(otherNumber, {
          'type': 'call_offer',
          'id': call.callId,
          'groupId': call.groupId,
          'callId': call.callId,
          'senderInternalNumber': _localInternalNumber(),
          'sdp': offer.sdp,
        }));
      }
    } catch (_) {
      // فشل إنشاء اتصال مع مشارك واحد لا يجب أن يُسقِط المكالمة كلها —
      // يبقى هذا المشارك بلا اتصال فعلي، والبقية غير متأثرين.
    } finally {
      _connectingTo.remove(otherNumber);
    }
  }

  Future<void> _drainPendingCandidates(String otherNumber) async {
    final pc = _peerConnections[otherNumber];
    final pending = _pendingCandidates[otherNumber];
    if (pc == null || pending == null) return;
    for (final candidate in pending) {
      await pc.addCandidate(candidate);
    }
    pending.clear();
  }

  void _checkIfCallEnded() {
    final call = currentCall;
    if (call == null || call.state != GroupCallState.active) return;
    if (_peerConnections.isEmpty) {
      unawaited(_endCall(reason: 'غادر جميع المشاركين الآخرين', notifyOthers: false));
    }
  }

  // -------------------------------------------------------------------
  // التحكم والتنظيف
  // -------------------------------------------------------------------

  void toggleMute() {
    final stream = _localStream;
    if (stream == null) return;
    isMuted = !isMuted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !isMuted;
    }
    _safeNotify();
  }

  void toggleCamera() {
    final stream = _localStream;
    if (stream == null || currentCall?.mediaType != CallMediaType.video || isScreenSharing) return;
    isCameraOff = !isCameraOff;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !isCameraOff;
    }
    _safeNotify();
  }

  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null || currentCall?.mediaType != CallMediaType.video || isScreenSharing) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  /// يستبدل مسار الفيديو المُرسَل لكل المشاركين المتصلين حاليًا بمسار
  /// التقاط الشاشة (أو العكس عند الإيقاف) — بلا حاجة لأي تفاوض SDP جديد؛
  /// replaceTrack يُحدِّث الاتصالات القائمة مباشرة.
  Future<void> toggleScreenShare() async {
    final call = currentCall;
    if (call == null || call.mediaType != CallMediaType.video) return;

    if (isScreenSharing) {
      final cameraTrack = _cameraTrack;
      if (cameraTrack == null) return;
      for (final pc in _peerConnections.values) {
        final senders = await pc.getSenders();
        for (final sender in senders.where((s) => s.track?.kind == 'video')) {
          await sender.replaceTrack(cameraTrack);
        }
      }
      localRenderer.srcObject = _localStream;
      final screenStream = _screenStream;
      _screenStream = null;
      if (screenStream != null) {
        for (final track in screenStream.getTracks()) {
          await track.stop();
        }
      }
      isScreenSharing = false;
      _safeNotify();
      return;
    }

    try {
      // يجب أن تحمل الخدمة الأمامية الدائمة نوع mediaProjection *قبل* طلب
      // الالتقاط، وإلا يرفضه أندرويد 14+ (راجع التعليق في
      // LocalConnectForegroundService.onStartCommand) — الخدمة لا تحمل هذا
      // النوع افتراضيًا عند إقلاع التطبيق العادي لتفادي رفض بدئها بالكامل.
      try {
        await const MethodChannel('local_connect/foreground_service')
            .invokeMethod<void>('enableMediaProjectionType');
      } catch (_) {
        // منصّة غير أندرويد، أو إصدار أقدم لا يحتاج هذا أصلًا — لا يمنع
        // المتابعة؛ getDisplayMedia أدناه هو الفحص الفعلي.
      }
      final screenStream = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final screenTrack = screenStream.getVideoTracks().first;
      _screenStream = screenStream;
      for (final pc in _peerConnections.values) {
        final senders = await pc.getSenders();
        for (final sender in senders.where((s) => s.track?.kind == 'video')) {
          await sender.replaceTrack(screenTrack);
        }
      }
      localRenderer.srcObject = screenStream;
      isScreenSharing = true;
      _safeNotify();
    } catch (_) {
      // رفض صلاحية المشاركة أو إلغاء المستخدم لنافذة اختيار الشاشة — لا
      // يجب أن يُسقِط المكالمة نفسها، تبقى isScreenSharing false ببساطة.
    }
  }

  Future<void> _ensureRenderers() async {
    if (_localRendererInitialized) return;
    await localRenderer.initialize();
    _localRendererInitialized = true;
  }

  Future<void> _ensureLocalMedia(CallMediaType mediaType) async {
    await _ensureRenderers();
    if (_localStream != null) return;
    final permissions = <Permission>[
      Permission.microphone,
      if (mediaType == CallMediaType.video) Permission.camera,
    ];
    final statuses = await permissions.request();
    if (statuses.values.any((status) => !status.isGranted)) {
      throw 'صلاحية الميكروفون${mediaType == CallMediaType.video ? '/الكاميرا' : ''} مرفوضة';
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': mediaType == CallMediaType.video ? {'facingMode': 'user'} : false,
    });
    if (mediaType == CallMediaType.video && _localStream!.getVideoTracks().isNotEmpty) {
      _cameraTrack = _localStream!.getVideoTracks().first;
    }
    localRenderer.srcObject = _localStream;
  }

  void _startRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (currentCall?.state == GroupCallState.ringing) {
        unawaited(_endCall(reason: 'لا يوجد رد', notifyOthers: true));
      }
    });
  }

  void _cancelRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  Future<void> _endCall({required String? reason, bool notifyOthers = true}) async {
    final call = currentCall;
    _cancelRingTimeout();
    unawaited(_sound.stopRingtone());
    unawaited(_sound.stopRingback());
    unawaited(_sound.cancelIncomingCallNotification());

    if (call != null && notifyOthers) {
      final everyoneToNotify = <String>{
        ..._peerConnections.keys,
        if (call.isInitiator) ...call.participants.keys,
      };
      for (final peerNumber in everyoneToNotify) {
        unawaited(_sendSignal(peerNumber, {
          'type': 'call_end',
          'id': call.callId,
          'groupId': call.groupId,
          'callId': call.callId,
          'senderInternalNumber': _localInternalNumber(),
        }));
      }
    }

    await _teardownAllConnections();

    if (call != null) {
      call.state = GroupCallState.ended;
      _safeNotify();
      _clearTimer?.cancel();
      _clearTimer = Timer(const Duration(seconds: 3), () {
        if (currentCall == call) {
          currentCall = null;
          _safeNotify();
        }
      });
    }
  }

  Future<void> _teardownPeerConnection(String otherNumber) async {
    final pc = _peerConnections.remove(otherNumber);
    _pendingCandidates.remove(otherNumber);
    _remoteDescriptionSet.remove(otherNumber);
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {
        // لا شيء.
      }
    }
    final renderer = _remoteRenderers.remove(otherNumber);
    if (renderer != null) {
      try {
        await renderer.dispose();
      } catch (_) {
        // لا شيء.
      }
    }
  }

  Future<void> _teardownAllConnections() async {
    for (final number in _peerConnections.keys.toList()) {
      await _teardownPeerConnection(number);
    }

    isMuted = false;
    isCameraOff = false;
    isScreenSharing = false;
    _cameraTrack = null;

    if (_localRendererInitialized) {
      localRenderer.srcObject = null;
    }

    final screenStream = _screenStream;
    _screenStream = null;
    if (screenStream != null) {
      for (final track in screenStream.getTracks()) {
        await track.stop();
      }
    }

    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ringTimer?.cancel();
    _clearTimer?.cancel();
    unawaited(_teardownAllConnections());
    unawaited(localRenderer.dispose());
    super.dispose();
  }
}
