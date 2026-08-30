import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/call_session.dart';
import 'call_sound_service.dart';

/// دالة إرسال إشارة مكالمة لرقم داخلي معيَّن — عادة [AppState.sendCallSignal]،
/// يُمرَّرها الطرف المستدعي بدل استيراد AppState هنا مباشرة (لتفادي اعتماد
/// دائري بين الخدمتين).
typedef CallSignalSender = Future<bool> Function(
  String peerInternalNumber,
  Map<String, dynamic> payload,
);

/// يدير دورة حياة مكالمة صوتية/مرئية واحدة عبر WebRTC: التقاط الوسائط
/// المحلية، تفاوض SDP (عرض/رد)، تبادل مرشّحات ICE، وحالة الاتصال —
/// باستخدام نفس سلسلة النقل الاحتياطية (Wi-Fi، بلوتوث، مُرحِّل) المستخدمة
/// للرسائل النصية، عبر [CallSignalSender] المُمرَّر من AppState.
///
/// خادم STUN عام واحد (Google) لاكتشاف عنوان IP العلني عند اجتياز NAT.
/// لا يوجد خادم TURN — فمكالمات عبر شبكات مقيَّدة جدًا (NAT متماثل مثلًا)
/// قد لا تنجح؛ هذا قيد معروف بلا حل بدون خادم TURN مخصَّص.
class CallService extends ChangeNotifier {
  CallService({
    required CallSignalSender sendSignal,
    required String Function() localInternalNumber,
    required String Function() localDisplayName,
    String? Function(String internalNumber)? contactDisplayNameFor,
    void Function(String peerInternalNumber, String peerDisplayName, CallMediaType mediaType)? onMissedCall,
  })  : _sendSignal = sendSignal,
        _localInternalNumber = localInternalNumber,
        _localDisplayName = localDisplayName,
        _contactDisplayNameFor = contactDisplayNameFor,
        _onMissedCall = onMissedCall {
    // يستقبل ضغطة زر "رد"/"رفض" على إشعار المكالمة الواردة الأصلي (انظر
    // CallActionReceiver.kt على جانب أندرويد) — ضروري لأن الشاشة الكاملة
    // قد لا تُفتَح تلقائيًا (أندرويد 14+ يقيّدها)، فيبقى هذان الزرّان
    // الطريقة الوحيدة للتفاعل مع المكالمة دون فتح التطبيق يدويًا أولًا.
    const MethodChannel('local_connect/call_actions').setMethodCallHandler((call) async {
      switch (call.method) {
        case 'answer':
          await acceptCall();
        case 'reject':
          await rejectCall();
      }
    });
  }

  final CallSignalSender _sendSignal;
  final String Function() _localInternalNumber;
  final String Function() _localDisplayName;

  /// يُستدعى عندما تنتهي مكالمة واردة دون أن يردّ عليها هذا الجهاز (انتهت
  /// المهلة، أو أنهاها الطرف المتصل قبل أن يُرَدّ عليها) — يُميَّز صراحة عن
  /// الرفض الصريح (rejectCall)، الذي لا يُعتبَر "مكالمة فائتة". راجع
  /// _endCall لمكان تحديد هذا الفرق فعليًا.
  final void Function(String peerInternalNumber, String peerDisplayName, CallMediaType mediaType)?
      _onMissedCall;

  /// يبحث عن اسم جهة اتصال محفوظ محليًا لرقم داخلي معيَّن، أو null إن لم
  /// تكن محفوظة. عند وجوده، يُفضَّل على الاسم الذي يدّعيه الطرف المتصل نفسه
  /// عبر الشبكة (`callerDisplayName`) — فجهة اتصال حفظتَها أنت باسم تعرفه
  /// أوثق من اسم قد لا يكون الطرف الآخر ضبطه أصلًا (يظهر عندها بالاسم
  /// الافتراضي العام لأي هوية جديدة في التطبيق).
  final String? Function(String internalNumber)? _contactDisplayNameFor;

  /// STUN وحده يكتشف عنوانك العام لمحاولة اتصال مباشر (hole punching)، لكن
  /// لا يعمل بديلًا إن فشلت المحاولة المباشرة — وهذا شائع جدًا خلف NAT
  /// المُشغِّلين المقيَّد (CGNAT، شائع على بيانات الجوال) حيث يفشل hole
  /// punching غالبًا. بدون خادم TURN يُرحِّل الوسائط كحل أخير، كانت أي
  /// مكالمة بين طرفين خلف مثل هذا NAT تفشل تمامًا بلا أي بديل. خادم TURN
  /// أدناه عام ومجاني (Open Relay Project) — حل مؤقّت عملي؛ الأفضل لاحقًا
  /// استضافة خادم TURN خاص (coturn) على نفس خادم المُرحِّل (SofiNet) لتحكّم
  /// وخصوصية أفضل، لكن هذا يحتاج وصولًا لإدارة الخادم غير متاح حاليًا هنا.
  static const Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443',
          'turn:openrelay.metered.ca:443?transport=tcp',
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  final CallSoundService _sound = CallSoundService();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _pendingOfferSdp;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;
  Timer? _ringTimer;
  Timer? _clearTimer;
  Timer? _videoUpgradeTimer;
  bool _disposed = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;

  CallSession? currentCall;
  bool isMuted = false;
  bool isSpeakerOn = false;
  bool isCameraOff = false;

  /// راجع CallSoundService.ensureFullScreenIntentPermission.
  Future<void> ensureFullScreenIntentPermission() => _sound.ensureFullScreenIntentPermission();

  /// راجع CallSoundService.hasFullScreenIntentPermission.
  Future<bool> hasFullScreenIntentPermission() => _sound.hasFullScreenIntentPermission();

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _ensureRenderers() async {
    if (_renderersInitialized) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersInitialized = true;
  }

  // -------------------------------------------------------------------
  // بدء مكالمة صادرة
  // -------------------------------------------------------------------

  Future<void> startCall({
    required String peerInternalNumber,
    required String peerDisplayName,
    required CallMediaType mediaType,
  }) async {
    if (currentCall != null) return; // مكالمة أخرى جارية بالفعل

    await _ensureRenderers();
    final callId = const Uuid().v4();
    currentCall = CallSession(
      callId: callId,
      peerInternalNumber: peerInternalNumber,
      peerDisplayName: peerDisplayName,
      direction: CallDirection.outgoing,
      mediaType: mediaType,
    );
    _safeNotify();

    try {
      await _openLocalMedia(mediaType);
      _pc = await createPeerConnection(_rtcConfiguration);
      _wirePeerConnectionCallbacks();
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': mediaType == CallMediaType.video,
      });
      await _pc!.setLocalDescription(offer);

      final delivered = await _sendSignal(peerInternalNumber, {
        'type': 'call_offer',
        'id': callId,
        'senderInternalNumber': _localInternalNumber(),
        'callerDisplayName': _localDisplayName(),
        'mediaType': mediaType.name,
        'sdp': offer.sdp,
      });

      if (!delivered) {
        await _endCall(reason: 'تعذّر الوصول للطرف الآخر الآن', notifyPeer: false);
        return;
      }
      _startRingTimeout();
      unawaited(_sound.playRingback());
    } catch (error) {
      await _endCall(reason: 'تعذّر بدء المكالمة: $error', notifyPeer: false);
    }
  }

  // -------------------------------------------------------------------
  // استقبال إشارات المكالمة (يُستدعى من AppState._handleIncomingWire)
  // -------------------------------------------------------------------

  Future<void> handleSignal(Map<String, dynamic> payload) async {
    switch (payload['type']) {
      case 'call_offer':
        await _handleIncomingOffer(payload);
      case 'call_answer':
        await _handleIncomingAnswer(payload);
      case 'call_ice_candidate':
        await _handleIncomingIceCandidate(payload);
      case 'call_reject':
        await _handleIncomingReject(payload);
      case 'call_end':
        await _handleIncomingEnd(payload);
      case 'call_video_upgrade_request':
        await _handleVideoUpgradeRequest(payload);
      case 'call_video_upgrade_response':
        await _handleVideoUpgradeResponse(payload);
      case 'call_renegotiate_offer':
        await _handleRenegotiateOffer(payload);
      case 'call_renegotiate_answer':
        await _handleRenegotiateAnswer(payload);
    }
  }

  Future<void> _handleIncomingOffer(Map<String, dynamic> payload) async {
    final callId = payload['id'];
    final senderInternalNumber = payload['senderInternalNumber'];
    final sdp = payload['sdp'];
    if (callId is! String || senderInternalNumber is! String || sdp is! String) return;

    if (currentCall != null) {
      // مشغول بمكالمة أخرى بالفعل — رفض تلقائي بدل تجاهل صامت، حتى يعرف
      // المتصل أن مكالمته لن تُجاب بدل أن تظل "ترن" له إلى أن تنتهي المهلة.
      unawaited(_sendSignal(senderInternalNumber, {
        'type': 'call_reject',
        'id': callId,
        'senderInternalNumber': _localInternalNumber(),
        'reason': 'busy',
      }));
      return;
    }

    await _ensureRenderers();
    final mediaType = payload['mediaType'] == 'video' ? CallMediaType.video : CallMediaType.audio;
    currentCall = CallSession(
      callId: callId,
      peerInternalNumber: senderInternalNumber,
      peerDisplayName: _contactDisplayNameFor?.call(senderInternalNumber) ??
          (payload['callerDisplayName'] as String?) ??
          senderInternalNumber,
      direction: CallDirection.incoming,
      mediaType: mediaType,
    );
    _pendingOfferSdp = sdp;
    _startRingTimeout();
    unawaited(_sound.playRingtone());
    unawaited(_sound.showIncomingCallNotification(
      callerName: currentCall!.peerDisplayName,
      callerNumber: currentCall!.peerInternalNumber,
      isVideo: currentCall!.mediaType == CallMediaType.video,
    ));
    _safeNotify();
  }

  /// يقبل مكالمة واردة جارٍ رنينها حاليًا — هنا فقط يُطلب إذن الكاميرا/
  /// الميكروفون فعليًا، وليس عند مجرّد وصول العرض، حتى لا يُفاجَأ المستخدم
  /// بطلب صلاحية قبل أن يقرر الردّ من الأساس.
  Future<void> acceptCall() async {
    final call = currentCall;
    final sdp = _pendingOfferSdp;
    if (call == null || call.direction != CallDirection.incoming || sdp == null) return;
    _cancelRingTimeout();
    unawaited(_sound.stopRingtone());
    unawaited(_sound.cancelIncomingCallNotification());
    call.state = CallState.connecting;
    _safeNotify();

    try {
      await _openLocalMedia(call.mediaType);
      _pc = await createPeerConnection(_rtcConfiguration);
      _wirePeerConnectionCallbacks();
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      await _drainPendingCandidates();

      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': call.mediaType == CallMediaType.video,
      });
      await _pc!.setLocalDescription(answer);

      await _sendSignal(call.peerInternalNumber, {
        'type': 'call_answer',
        'id': call.callId,
        'senderInternalNumber': _localInternalNumber(),
        'sdp': answer.sdp,
      });
    } catch (error) {
      await _endCall(reason: 'تعذّر قبول المكالمة: $error');
    }
  }

  Future<void> rejectCall() async {
    final call = currentCall;
    if (call == null || call.direction != CallDirection.incoming) return;
    unawaited(_sendSignal(call.peerInternalNumber, {
      'type': 'call_reject',
      'id': call.callId,
      'senderInternalNumber': _localInternalNumber(),
    }));
    // رفض صريح من المستخدم — لا يُحتسَب "مكالمة فائتة" (ذاك خاص بعدم الرد
    // إطلاقًا)، رغم أن الشرط الآلي في _endCall كان سيُصنِّفه كذلك لولا هذا
    // الاستثناء الصريح.
    await _endCall(reason: null, notifyPeer: false, declinedByUser: true);
  }

  Future<void> endCall() => _endCall(reason: null, notifyPeer: true);

  Future<void> _handleIncomingAnswer(Map<String, dynamic> payload) async {
    final call = currentCall;
    final pc = _pc;
    final sdp = payload['sdp'];
    if (call == null || pc == null || sdp is! String || payload['id'] != call.callId) return;
    _cancelRingTimeout();
    unawaited(_sound.stopRingback());
    call.state = CallState.connecting;
    _safeNotify();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet = true;
    await _drainPendingCandidates();
  }

  Future<void> _handleIncomingIceCandidate(Map<String, dynamic> payload) async {
    final call = currentCall;
    final candidate = payload['candidate'];
    if (call == null || _pc == null || payload['id'] != call.callId || candidate is! String) return;

    final iceCandidate = RTCIceCandidate(
      candidate,
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(iceCandidate);
    } else {
      await _pc!.addCandidate(iceCandidate);
    }
  }

  Future<void> _drainPendingCandidates() async {
    for (final candidate in _pendingRemoteCandidates) {
      await _pc?.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  Future<void> _handleIncomingReject(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null || payload['id'] != call.callId) return;
    final busy = payload['reason'] == 'busy';
    await _endCall(
      reason: busy ? 'الطرف الآخر مشغول بمكالمة أخرى' : 'رفض الطرف الآخر المكالمة',
      notifyPeer: false,
    );
  }

  Future<void> _handleIncomingEnd(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null || payload['id'] != call.callId) return;
    await _endCall(reason: 'أنهى الطرف الآخر المكالمة', notifyPeer: false);
  }

  // -------------------------------------------------------------------
  // التحويل من صوت لفيديو أثناء مكالمة جارية (بلا إنهائها/بدء مكالمة جديدة)
  // -------------------------------------------------------------------

  /// يطلب من الطرف الآخر الموافقة على تحويل المكالمة الصوتية الجارية
  /// لفيديو — لا تُفتَح الكاميرا هنا إطلاقًا، فقط طلب. الكاميرا تُفتَح لاحقًا
  /// فقط بعد وصول موافقة صريحة (راجع _handleVideoUpgradeResponse)، تحقيقًا
  /// لمطلب "لا يتم تشغيل كاميرا الطرف الآخر تلقائيًا بدون موافقته".
  Future<void> requestVideoUpgrade() async {
    final call = currentCall;
    if (call == null ||
        call.state != CallState.active ||
        call.mediaType != CallMediaType.audio ||
        call.pendingOutgoingVideoUpgrade) {
      return;
    }
    call.pendingOutgoingVideoUpgrade = true;
    _safeNotify();
    final delivered = await _sendSignal(call.peerInternalNumber, {
      'type': 'call_video_upgrade_request',
      'id': call.callId,
      'senderInternalNumber': _localInternalNumber(),
    });
    if (!delivered) {
      call.pendingOutgoingVideoUpgrade = false;
      _safeNotify();
      return;
    }
    _videoUpgradeTimer?.cancel();
    _videoUpgradeTimer = Timer(const Duration(seconds: 20), () {
      // لم يردّ الطرف الآخر خلال المهلة — يُعامَل كرفض ضمني، فتستمر المكالمة
      // الصوتية بشكل طبيعي (نفس مطلب "إذا لم يرد").
      if (currentCall == call && call.pendingOutgoingVideoUpgrade) {
        call.pendingOutgoingVideoUpgrade = false;
        _safeNotify();
      }
    });
  }

  void _cancelVideoUpgradeTimeout() {
    _videoUpgradeTimer?.cancel();
    _videoUpgradeTimer = null;
  }

  Future<void> _handleVideoUpgradeRequest(Map<String, dynamic> payload) async {
    final call = currentCall;
    if (call == null ||
        payload['id'] != call.callId ||
        call.state != CallState.active ||
        call.mediaType != CallMediaType.audio) {
      return;
    }
    call.pendingIncomingVideoUpgrade = true;
    _safeNotify();
  }

  /// يُستدعى من واجهة المستخدم عندما يقبل/يرفض طلبًا واردًا للتحويل لفيديو
  /// (راجع _handleVideoUpgradeRequest أعلاه الذي يُظهِر الطلب أولًا).
  Future<void> respondToVideoUpgrade(bool accepted) async {
    final call = currentCall;
    if (call == null || !call.pendingIncomingVideoUpgrade) return;
    call.pendingIncomingVideoUpgrade = false;
    _safeNotify();
    await _sendSignal(call.peerInternalNumber, {
      'type': 'call_video_upgrade_response',
      'id': call.callId,
      'senderInternalNumber': _localInternalNumber(),
      'accepted': accepted,
    });
    // القبول لا يفتح الكاميرا هنا — ذلك يحدث لاحقًا في _handleRenegotiateOffer
    // عند وصول عرض SDP الفعلي من الطرف الطالب، بعد أن يضيف هو مسار الفيديو
    // ويبدأ التفاوض. هذا يبقي فتح كاميرتَي الطرفين متزامنًا مع جولة تفاوض
    // SDP واحدة فقط، بدل تفاوضين منفصلين.
  }

  Future<void> _handleVideoUpgradeResponse(Map<String, dynamic> payload) async {
    final call = currentCall;
    final pc = _pc;
    if (call == null || pc == null || payload['id'] != call.callId || !call.pendingOutgoingVideoUpgrade) {
      return;
    }
    _cancelVideoUpgradeTimeout();
    call.pendingOutgoingVideoUpgrade = false;
    if (payload['accepted'] != true) {
      _safeNotify();
      return;
    }
    try {
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });
      final videoTrack = videoStream.getVideoTracks().first;
      await pc.addTrack(videoTrack, _localStream ?? videoStream);
      _localStream?.addTrack(videoTrack);
      localRenderer.srcObject = _localStream ?? videoStream;
      isCameraOff = false;

      final offer = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
      await pc.setLocalDescription(offer);
      await _sendSignal(call.peerInternalNumber, {
        'type': 'call_renegotiate_offer',
        'id': call.callId,
        'senderInternalNumber': _localInternalNumber(),
        'sdp': offer.sdp,
      });
      call.mediaType = CallMediaType.video;
      _safeNotify();
    } catch (_) {
      // تعذّر فتح الكاميرا أو التفاوض — المكالمة الصوتية تستمر بلا أي
      // تعطيل، فقط يبقى التحويل لفيديو غير متاح هذه المرة.
    }
  }

  Future<void> _handleRenegotiateOffer(Map<String, dynamic> payload) async {
    final call = currentCall;
    final pc = _pc;
    final sdp = payload['sdp'];
    if (call == null || pc == null || payload['id'] != call.callId || sdp is! String) return;
    try {
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });
      final videoTrack = videoStream.getVideoTracks().first;
      await pc.addTrack(videoTrack, _localStream ?? videoStream);
      _localStream?.addTrack(videoTrack);
      localRenderer.srcObject = _localStream ?? videoStream;
      isCameraOff = false;

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      final answer = await pc.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
      await pc.setLocalDescription(answer);
      await _sendSignal(call.peerInternalNumber, {
        'type': 'call_renegotiate_answer',
        'id': call.callId,
        'senderInternalNumber': _localInternalNumber(),
        'sdp': answer.sdp,
      });
      call.mediaType = CallMediaType.video;
      _safeNotify();
    } catch (_) {
      // فشل تفعيل الفيديو من هذا الطرف — المكالمة الصوتية تستمر بلا تعطيل.
    }
  }

  Future<void> _handleRenegotiateAnswer(Map<String, dynamic> payload) async {
    final call = currentCall;
    final pc = _pc;
    final sdp = payload['sdp'];
    if (call == null || pc == null || payload['id'] != call.callId || sdp is! String) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  // -------------------------------------------------------------------
  // التحكم أثناء المكالمة
  // -------------------------------------------------------------------

  Future<void> toggleMute() async {
    final stream = _localStream;
    if (stream == null) return;
    isMuted = !isMuted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !isMuted;
    }
    _safeNotify();
  }

  Future<void> toggleSpeaker() async {
    isSpeakerOn = !isSpeakerOn;
    await Helper.setSpeakerphoneOn(isSpeakerOn);
    _safeNotify();
  }

  Future<void> toggleCamera() async {
    final stream = _localStream;
    if (stream == null || currentCall?.mediaType != CallMediaType.video) return;
    isCameraOff = !isCameraOff;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !isCameraOff;
    }
    _safeNotify();
  }

  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null || currentCall?.mediaType != CallMediaType.video) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  // -------------------------------------------------------------------
  // مساعدات داخلية
  // -------------------------------------------------------------------

  /// يطلب صلاحيات الميكروفون (ودائمًا الكاميرا إن كانت مكالمة مرئية) قبل
  /// محاولة التقاط الوسائط — رفض واضح هنا أفضل من استثناء غامض من WebRTC
  /// نفسه لاحقًا.
  Future<void> _openLocalMedia(CallMediaType mediaType) async {
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
    localRenderer.srcObject = _localStream;
    isSpeakerOn = mediaType == CallMediaType.video;
    unawaited(Helper.setSpeakerphoneOn(isSpeakerOn));
  }

  void _wirePeerConnectionCallbacks() {
    final pc = _pc!;
    final call = currentCall!;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      unawaited(_sendSignal(call.peerInternalNumber, {
        'type': 'call_ice_candidate',
        'id': call.callId,
        'senderInternalNumber': _localInternalNumber(),
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }));
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        _safeNotify();
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (call.state != CallState.active) {
          call.state = CallState.active;
          call.connectedAt = DateTime.now();
          _safeNotify();
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        unawaited(_endCall(reason: 'انقطع الاتصال', notifyPeer: false));
      }
    };
  }

  void _startRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (currentCall?.state == CallState.ringing) {
        unawaited(_endCall(reason: 'لا يوجد رد', notifyPeer: true));
      }
    });
  }

  void _cancelRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  Future<void> _endCall({
    required String? reason,
    bool notifyPeer = true,
    bool declinedByUser = false,
  }) async {
    final call = currentCall;
    // مكالمة واردة انتهت (بالمهلة أو لأن المتصل أنهاها هو) قبل أن يُرَدّ
    // عليها إطلاقًا = فائتة. الرفض الصريح (declinedByUser) مستثنى عمدًا —
    // ليس "فوات"، بل قرار واعٍ من المستخدم.
    final wasMissed = !declinedByUser &&
        call != null &&
        call.direction == CallDirection.incoming &&
        call.state == CallState.ringing;
    _cancelRingTimeout();
    _cancelVideoUpgradeTimeout();
    unawaited(_sound.stopRingtone());
    unawaited(_sound.stopRingback());
    unawaited(_sound.cancelIncomingCallNotification());
    if (call != null && notifyPeer && call.state != CallState.ended) {
      unawaited(_sendSignal(call.peerInternalNumber, {
        'type': 'call_end',
        'id': call.callId,
        'senderInternalNumber': _localInternalNumber(),
      }));
    }
    await _teardownMedia();

    if (call != null) {
      call.state = CallState.ended;
      call.endReason = reason;
      if (wasMissed) _onMissedCall?.call(call.peerInternalNumber, call.peerDisplayName, call.mediaType);
      _safeNotify();
      // يُبقي بطاقة "انتهت المكالمة" ظاهرة لحظات قبل اختفائها، بدل قفل
      // الواجهة فورًا لمكالمة سابقة.
      _clearTimer?.cancel();
      _clearTimer = Timer(const Duration(seconds: 3), () {
        if (currentCall == call) {
          currentCall = null;
          _safeNotify();
        }
      });
    }
  }

  Future<void> _teardownMedia() async {
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    _pendingOfferSdp = null;
    try {
      await _pc?.close();
    } catch (_) {
      // لا شيء — الهدف فقط تفادي إسقاط عملية الإنهاء بسبب خطأ في التنظيف.
    }
    _pc = null;

    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      // إيقاف المسارات (getTracks/stop أعلاه) لا يُصفِّر بالضرورة وضع صوت
      // النظام (AudioManager على أندرويد) الذي تضبطه المكالمة عند بدئها
      // (سمّاعة خارجية/داخلية) — يبقى أحيانًا "عالقًا" على وضع المكالمة رغم
      // توقف كل المسارات فعليًا، فيظهر مؤشر الميكروفون في النظام وكأنه لا
      // يزال نشطًا. إعادته للوضع الطبيعي (سمّاعة داخلية) هنا صراحة.
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (_) {
        // لا شيء — تحسين إضافي، ليس شرطًا لإنهاء المكالمة بنجاح.
      }
    }
    isSpeakerOn = false;
    isMuted = false;
    // ضبط srcObject على مُصيِّر لم يُهيَّأ بعد (initialize()) يرمي استثناءً —
    // يحدث هذا فعليًا عند dispose لتطبيق لم تُجرَ فيه أي مكالمة إطلاقًا قط.
    if (_renderersInitialized) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ringTimer?.cancel();
    _clearTimer?.cancel();
    _videoUpgradeTimer?.cancel();
    unawaited(_teardownMedia());
    unawaited(localRenderer.dispose());
    unawaited(remoteRenderer.dispose());
    super.dispose();
  }
}
