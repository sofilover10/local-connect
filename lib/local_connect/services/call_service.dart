import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../models/call_session.dart';
import 'call_rtc_gateway.dart';
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
/// خادم STUN عام (Google) لاكتشاف عنوان IP العلني، وخوادم TURN (عدّة
/// مسارات: UDP/TCP/TLS عبر 443) كبديل ترحيل أخير عندما يستحيل الاتصال
/// المباشر خلف NAT مقيَّد/CGNAT — راجع [_rtcConfiguration].
///
/// السجل التشخيصي ([_logDiagnostic]) يغطّي كل مرحلة: القبول، تبادل SDP،
/// عدد وأنواع مرشّحات ICE (host/srflx/relay)، حالات التجميع والاتصال، زوج
/// المرشّحين المختار عند النجاح، وسبب الإنهاء النهائي — يظهر كله في شاشة
/// "فحص الأخطاء" ليُعرَف موضع الفشل بالضبط دون أدوات خارجية.
class CallService extends ChangeNotifier {
  CallService({
    required CallSignalSender sendSignal,
    required String Function() localInternalNumber,
    required String Function() localDisplayName,
    String? Function(String internalNumber)? contactDisplayNameFor,
    void Function(String peerInternalNumber, String peerDisplayName, CallMediaType mediaType)? onMissedCall,
    void Function(String message)? onCallDiagnostic,
    CallRtcGateway? rtcGateway,
    @visibleForTesting Duration ringTimeout = const Duration(seconds: 45),
    @visibleForTesting Duration reconnectGrace = const Duration(seconds: 15),
  })  : _sendSignal = sendSignal,
        _localInternalNumber = localInternalNumber,
        _localDisplayName = localDisplayName,
        _contactDisplayNameFor = contactDisplayNameFor,
        _onMissedCall = onMissedCall,
        _onCallDiagnostic = onCallDiagnostic,
        _rtc = rtcGateway ?? FlutterWebRtcGateway(),
        _ringTimeout = ringTimeout,
        _reconnectGrace = reconnectGrace {
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

  /// بوابة طبقة WebRTC/المنصّة — حقيقية في الإنتاج، وهمية في اختبارات
  /// regression لدورة حياة المكالمة (انظر call_rtc_gateway.dart).
  final CallRtcGateway _rtc;

  /// مهلة الرنين ومهلة استعادة الاتصال — قابلة للحقن في الاختبارات فقط؛
  /// القيم الافتراضية هي نفسها الثوابت السابقة حرفيًا (45 و15 ثانية).
  final Duration _ringTimeout;
  final Duration _reconnectGrace;

  /// يُستدعى عندما تنتهي مكالمة واردة دون أن يردّ عليها هذا الجهاز (انتهت
  /// المهلة، أو أنهاها الطرف المتصل قبل أن يُرَدّ عليها) — يُميَّز صراحة عن
  /// الرفض الصريح (rejectCall)، الذي لا يُعتبَر "مكالمة فائتة". راجع
  /// _endCall لمكان تحديد هذا الفرق فعليًا.
  final void Function(String peerInternalNumber, String peerDisplayName, CallMediaType mediaType)?
      _onMissedCall;

  /// سجل تشخيصي مرئي لدورة حياة المكالمة (حالة ICE، نوع الشبكة، سبب فشل
  /// الاتصال...) — يُسجَّل عبر AppState.recordError ليظهر مباشرة في شاشة
  /// "فحص الأخطاء" دون الحاجة لأي أداة تصحيح خارجية (adb logcat وغيرها)
  /// غير متاحة عمليًا لمعظم من يختبر التطبيق ميدانيًا.
  final void Function(String message)? _onCallDiagnostic;
  void _logDiagnostic(String message) => _onCallDiagnostic?.call(message);

  /// نفس منطق تصنيف واجهات بيانات الجوال المستخدَم أصلًا في
  /// LanDiscoveryService — لا حزمة اتصال منفصلة (connectivity_plus وغيرها)
  /// هنا، فقط فحص اسم الواجهة النشطة (rmnet/ccmni/wwan/pdp لبيانات الجوال،
  /// أي شيء آخر يُعتبَر Wi-Fi/إيثرنت). كافٍ لتصنيف تشخيصي، ليس دقيقًا
  /// 100% على كل الشرائح، لكنه يعطي إشارة واضحة في السجل بلا اعتماد جديد.
  static const _cellularInterfacePrefixes = ['rmnet', 'ccmni', 'wwan', 'pdp'];

  Future<void> _logCurrentNetworkType() async {
    try {
      final interfaces =
          await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      final names = interfaces.map((i) => i.name.toLowerCase()).toList();
      final hasCellular = names.any((n) => _cellularInterfacePrefixes.any(n.startsWith));
      final hasWifi = names.any((n) => !_cellularInterfacePrefixes.any(n.startsWith));
      final label = hasCellular && hasWifi
          ? 'Wi-Fi + بيانات جوال معًا'
          : hasCellular
              ? 'بيانات جوال'
              : hasWifi
                  ? 'Wi-Fi/إيثرنت'
                  : 'غير معروف';
      _logDiagnostic('نوع الشبكة الحالي: $label (واجهات: ${names.join(", ")})');
    } catch (error) {
      _logDiagnostic('تعذّرت قراءة نوع الشبكة: $error');
    }
  }

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
  ///
  /// عدّة مسارات TURN مختلفة (UDP، TCP، وTLS عبر المنفذ 443 تحديدًا) —
  /// كثير من شبكات بيانات الجوال تحجب أو تقيّد UDP الخام (وهو ما يعتمد
  /// عليه STUN/TURN الأساسي)، بينما حركة TLS على المنفذ 443 تبدو كأي اتصال
  /// HTTPS عادي فتمرّ فعليًا عبر تقريبًا كل شبكة/جدار حماية. ICE يجرّب كل
  /// هذه المسارات تلقائيًا ويختار أول ما ينجح؛ مسار غير مدعوم من الخادم
  /// يُتجاهَل بصمت بلا تعطيل البقية.
  static const Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443',
          'turn:openrelay.metered.ca:443?transport=tcp',
          'turns:openrelay.metered.ca:443?transport=tcp',
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
    await _rtc.initializeRenderers(localRenderer, remoteRenderer);
    _renderersInitialized = true;
  }

  /// مكالمة منتهية لم تُزَل بطاقتها بعد من الواجهة (نافذة الثواني الثلاث
  /// بعد الإنهاء) يجب ألا تحجب مكالمة جديدة — بدء مكالمة فور انتهاء
  /// السابقة مطلب صريح، فنُفرِغ المنتهية هنا فورًا بدل انتظار المؤقّت.
  void _clearEndedCallImmediately() {
    if (currentCall?.state != CallState.ended) return;
    _clearTimer?.cancel();
    currentCall = null;
  }

  // -------------------------------------------------------------------
  // بدء مكالمة صادرة
  // -------------------------------------------------------------------

  Future<void> startCall({
    required String peerInternalNumber,
    required String peerDisplayName,
    required CallMediaType mediaType,
  }) async {
    _clearEndedCallImmediately();
    if (currentCall != null) return; // مكالمة أخرى جارية بالفعل

    _callAttemptStartedAt = DateTime.now();
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
      _pc = await _rtc.createConnection(_rtcConfiguration);
      _wirePeerConnectionCallbacks();
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      _logDiagnostic('بدء مكالمة صادرة (${mediaType.name}) إلى $peerInternalNumber');
      unawaited(_logCurrentNetworkType());
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': mediaType == CallMediaType.video,
      });
      await _pc!.setLocalDescription(offer);

      final delivered = await _sendSignalWithRetry(
        peerInternalNumber,
        {
          'type': 'call_offer',
          'id': callId,
          'senderInternalNumber': _localInternalNumber(),
          'callerDisplayName': _localDisplayName(),
          'mediaType': mediaType.name,
          'sdp': offer.sdp,
          // ختم زمني — يتيح للطرف المستقبِل رفض عرض قديم مخزَّن لدى
          // المُرحِّل (الذي يحفظ الحمولات ويسلّمها عند عودة الاتصال)، فلا
          // يرنّ الجهاز فجأة لمكالمة ميّتة من محاولة سابقة انتهت أصلًا.
          'sentAt': DateTime.now().toIso8601String(),
        },
        label: 'call_offer',
      );

      if (!delivered) {
        _logDiagnostic('فشل إيصال call_offer نهائيًا — إنهاء المحاولة');
        await _endCall(reason: 'تعذّر الوصول للطرف الآخر الآن', notifyPeer: false);
        return;
      }
      _logDiagnostic('وصل call_offer — بانتظار رد الطرف الآخر (رنين)');
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

    // رفض العروض القديمة: المُرحِّل المركزي يخزّن الحمولات ويسلّمها عند
    // عودة الاتصال (مثلًا فور اتصال الهاتف بشبكة Wi-Fi جديدة)، فيصل عرض
    // مكالمة من محاولة سابقة انتهت منذ زمن — فيرنّ الجهاز لمكالمة ميّتة
    // لا متصل حقيقي خلفها، وتُسجَّل لاحقًا كـ"مكالمة فائتة" وهمية. أي عرض
    // أقدم من مهلة الرنين نفسها (45 ثانية، بهامش) لا معنى لعرضه إطلاقًا —
    // المتصل الأصلي أنهى محاولته فعلًا. عروض بلا ختم زمني (إصدار قديم لدى
    // الطرف الآخر) تُقبَل كالسابق حفاظًا على التوافق.
    final sentAtRaw = payload['sentAt'];
    if (sentAtRaw is String) {
      final sentAt = DateTime.tryParse(sentAtRaw);
      final age = sentAt == null ? null : DateTime.now().difference(sentAt);
      if (age != null && age > const Duration(seconds: 60)) {
        _logDiagnostic(
            'تجاهُل call_offer قديم من $senderInternalNumber (عمره ${age.inSeconds} ثانية) — غالبًا مخزَّن لدى المُرحِّل من محاولة سابقة منتهية، لا متصل حقيقي الآن');
        return;
      }
    }

    _clearEndedCallImmediately();
    if (currentCall != null) {
      // مشغول بمكالمة أخرى بالفعل — رفض تلقائي بدل تجاهل صامت، حتى يعرف
      // المتصل أن مكالمته لن تُجاب بدل أن تظل "ترن" له إلى أن تنتهي المهلة.
      // (لا يوجد Call Waiting مدروس بعد — رفض مشغول صريح هو السلوك
      // المقصود حاليًا، ورغم ذلك لا تُفتَح أي وسائط أو اتصال لهذا العرض.)
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
    // بيانات تشخيصية مباشرة لمشكلة "لا تظهر شاشة المكالمة فوق شاشة القفل" —
    // إن كانت هذه الصلاحية false هنا، فهذا يؤكد أن السبب هو الصلاحية
    // تحديدًا (يُصلَح من شاشة "فحص الأخطاء" ← زر "إصلاح")؛ إن كانت true
    // ولا تزال المشكلة قائمة، فالسبب شيء آخر (غالبًا تقييد خاص بمصنّع
    // الجهاز يتجاوز واجهات أندرويد القياسية).
    unawaited(hasFullScreenIntentPermission().then(
      (granted) => _logDiagnostic('مكالمة واردة: صلاحية الشاشة الكاملة = $granted'),
    ));
    unawaited(_logCurrentNetworkType());
    _safeNotify();
  }

  /// يقبل مكالمة واردة جارٍ رنينها حاليًا — هنا فقط يُطلب إذن الكاميرا/
  /// الميكروفون فعليًا، وليس عند مجرّد وصول العرض، حتى لا يُفاجَأ المستخدم
  /// بطلب صلاحية قبل أن يقرر الردّ من الأساس.
  Future<void> acceptCall() async {
    final call = currentCall;
    final sdp = _pendingOfferSdp;
    if (call == null || call.direction != CallDirection.incoming || sdp == null) return;
    _callAttemptStartedAt = DateTime.now();
    _cancelRingTimeout();
    unawaited(_sound.stopRingtone());
    unawaited(_sound.cancelIncomingCallNotification());
    call.state = CallState.connecting;
    _safeNotify();

    try {
      _logDiagnostic('تم القبول محليًا — جارٍ تجهيز الوسائط والرد');
      await _openLocalMedia(call.mediaType);
      _pc = await _rtc.createConnection(_rtcConfiguration);
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

      // حرِج: قبل هذا الإصلاح لم يُتحقَّق من نجاح إيصال call_answer إطلاقًا
      // — لو فشل (شائع عبر المُرحِّل بين شبكتين مختلفتين)، يبقى هذا الجهاز
      // "جارٍ الاتصال..." بصمت حتى تنتهي مهلة رنين المُتصِل (45 ثانية)
      // فيُنهي هو المكالمة بـ"لا يوجد رد" رغم أن الطرف الآخر ردّ عليها
      // فعليًا. الآن: إعادة محاولة، وإن فشلت نهائيًا، إنهاء واضح فورًا بدل
      // الانتظار الصامت.
      final delivered = await _sendSignalWithRetry(
        call.peerInternalNumber,
        {
          'type': 'call_answer',
          'id': call.callId,
          'senderInternalNumber': _localInternalNumber(),
          'sdp': answer.sdp,
        },
        label: 'call_answer',
      );
      if (!delivered) {
        _logDiagnostic('فشل إيصال call_answer نهائيًا — إنهاء المكالمة فورًا بدل الانتظار الصامت');
        await _endCall(reason: 'تعذّر إبلاغ الطرف الآخر بالقبول — تحقّق من الاتصال بالإنترنت', notifyPeer: false);
        return;
      }
      _logDiagnostic('وصل call_answer — بانتظار اكتمال اتصال ICE/WebRTC');
    } catch (error) {
      _logDiagnostic('استثناء أثناء قبول المكالمة: $error');
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
    _logDiagnostic('وصل call_answer — الطرف الآخر قبِل فعليًا، جارٍ تفاوض ICE/WebRTC');
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
    _logDiagnostic('مرشّح ICE وارد من الطرف الآخر: ${_candidateType(candidate)}');

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

    if (call.pendingOutgoingVideoUpgrade) {
      // كلا الطرفين طلب التحويل تقريبًا بنفس اللحظة (glare) — بما أن كليهما
      // أراد الفيديو أصلًا، نُعامِل هذا كموافقة متبادلة تلقائية بدل إظهار
      // طلبين منفصلين قد يتجاهلهما الطرفان أو يتعارضان (كلا الجهازين
      // بانتظار رد الآخر إلى الأبد — بالضبط ما أُبلِغ عنه). لتفادي تعارض
      // SDP (كلا الطرفين يُنشئ عرضًا بنفس اللحظة)، يُحدَّد الطرف الذي يُكمل
      // التفاوض فعليًا حتميًا عبر مقارنة الرقمين الداخليين — كلا الجهازين
      // يصل لنفس القرار محليًا بلا حاجة لتبادل رسالة إضافية.
      _cancelVideoUpgradeTimeout();
      call.pendingOutgoingVideoUpgrade = false;
      if (_localInternalNumber().compareTo(call.peerInternalNumber) < 0) {
        await _beginVideoUpgradeOffer(call);
      }
      // وإلا: الطرف الآخر هو من يُكمل بإرسال عرضه (call_renegotiate_offer)،
      // الذي سيصل ويُعالَج في _handleRenegotiateOffer عادةً.
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
    if (call == null || payload['id'] != call.callId || !call.pendingOutgoingVideoUpgrade) {
      return;
    }
    _cancelVideoUpgradeTimeout();
    call.pendingOutgoingVideoUpgrade = false;
    if (payload['accepted'] != true) {
      _safeNotify();
      return;
    }
    await _beginVideoUpgradeOffer(call);
  }

  /// يفتح كاميرا هذا الجهاز ويُنشئ عرض SDP جديدًا (renegotiation) على نفس
  /// اتصال WebRTC القائم فعليًا، بعد التأكد من موافقة الطرف الآخر (أو حسم
  /// حالة طلب متزامن — راجع _handleVideoUpgradeRequest). مُستخرَجة كدالة
  /// مشتركة حتى لا يتكرر نفس منطق فتح الكاميرا/التفاوض في كلا المسارين.
  Future<void> _beginVideoUpgradeOffer(CallSession call) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final videoStream = await _rtc.getCameraStream();
      final videoTrack = videoStream.getVideoTracks().first;
      await pc.addTrack(videoTrack, _localStream ?? videoStream);
      _localStream?.addTrack(videoTrack);
      _rtc.showLocalStream(localRenderer, _localStream ?? videoStream);
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
      final videoStream = await _rtc.getCameraStream();
      final videoTrack = videoStream.getVideoTracks().first;
      await pc.addTrack(videoTrack, _localStream ?? videoStream);
      _localStream?.addTrack(videoTrack);
      _rtc.showLocalStream(localRenderer, _localStream ?? videoStream);
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
    await _rtc.setSpeakerphoneOn(isSpeakerOn);
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
    await _rtc.switchCamera(tracks.first);
  }

  // -------------------------------------------------------------------
  // مساعدات داخلية
  // -------------------------------------------------------------------

  /// يطلب صلاحيات الميكروفون (ودائمًا الكاميرا إن كانت مكالمة مرئية) قبل
  /// محاولة التقاط الوسائط — رفض واضح هنا أفضل من استثناء غامض من WebRTC
  /// نفسه لاحقًا. الصلاحيات نفسها عبر البوابة حتى لا تُضرب قنوات المنصّة
  /// في الاختبارات.
  Future<void> _openLocalMedia(CallMediaType mediaType) async {
    await _rtc.ensureMediaPermissions(video: mediaType == CallMediaType.video);

    _localStream = await _rtc.getUserMedia(video: mediaType == CallMediaType.video);
    _rtc.showLocalStream(localRenderer, _localStream);
    isSpeakerOn = mediaType == CallMediaType.video;
    unawaited(_rtc.setSpeakerphoneOn(isSpeakerOn));
  }

  RTCPeerConnectionState? _lastConnectionState;
  Timer? _reconnectGraceTimer;

  /// لحظة بدء هذه المحاولة (بدء مكالمة صادرة، أو ضغط "قبول" لواردة) —
  /// تُستخدَم لحساب المدة المستغرقة حتى تأسيس الاتصال في السجل التشخيصي
  /// ("الوقت الذي استغرقته كل مرحلة").
  DateTime? _callAttemptStartedAt;

  /// عدّاد أنواع مرشّحات ICE المحلية المُجمَّعة في هذه المحاولة (host/
  /// srflx/relay) — يُلخَّص عند اكتمال التجميع ليُعرَف فورًا هل أنتج خادم
  /// TURN مرشّح relay فعلًا على هذه الشبكة أم لا (لا relay = الاتصال خلف
  /// CGNAT سيفشل غالبًا).
  final Map<String, int> _localCandidateCounts = {};

  /// نوع مرشّح ICE من نص SDP الخام — "host" (شبكة محلية مباشرة)، "srflx"
  /// (عنوان عام مكتشَف عبر STUN)، أو "relay" (عبر خادم TURN، آخر بديل).
  /// يظهر في سجل التشخيص ليُعرَف بوضوح هل الاتصال مباشر أم عبر TURN —
  /// مطلوب صراحة لتشخيص أعطال بيانات الجوال/CGNAT.
  String _candidateType(String? candidateLine) {
    if (candidateLine == null) return 'unknown';
    return RegExp(r' typ (\w+)').firstMatch(candidateLine)?.group(1) ?? 'unknown';
  }

  /// يرسل إشارة مكالمة مع إعادة محاولة قصيرة عند الفشل — كانت كل إشارات
  /// المكالمة (العرض، الرد، مرشّحات ICE) "أرسل ونسَ" بلا أي إعادة محاولة.
  /// هذا خطير خصوصًا لإشارة "call_answer": لو فشل إيصالها للمُتصِل الأصلي
  /// (شائع عبر المُرحِّل على شبكتين مختلفتين)، يبقى الطرف القابِل عالقًا في
  /// "جارٍ الاتصال..." بصمت حتى تنتهي مهلة رنين المُتصِل (45 ثانية) فيُنهي
  /// هو المكالمة بسبب "لا يوجد رد" — رغم أن الطرف الآخر ردّ عليها فعليًا.
  /// يُستخدَم أيضًا لمرشّحات ICE، حيث فقدان مرشّح واحد فقط (خصوصًا مرشّح
  /// TURN، غالبًا الوحيد القابل للعمل خلف CGNAT) على شبكة جوال متذبذبة قد
  /// يمنع نجاح الاتصال بالكامل رغم وجود مسار صالح نظريًا.
  Future<bool> _sendSignalWithRetry(String peer, Map<String, dynamic> payload, {String label = ''}) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (await _sendSignal(peer, payload)) {
        if (attempt > 1) _logDiagnostic('$label: نجح الإرسال بعد إعادة المحاولة رقم $attempt');
        return true;
      }
      await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
    }
    _logDiagnostic('$label: فشل الإرسال بعد 3 محاولات');
    return false;
  }

  void _wirePeerConnectionCallbacks() {
    final pc = _pc!;
    final call = currentCall!;
    _lastConnectionState = null;
    _localCandidateCounts.clear();
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      final type = _candidateType(candidate.candidate);
      _localCandidateCounts[type] = (_localCandidateCounts[type] ?? 0) + 1;
      _logDiagnostic('مرشّح ICE محلي: $type');
      unawaited(_sendSignalWithRetry(
        call.peerInternalNumber,
        {
          'type': 'call_ice_candidate',
          'id': call.callId,
          'senderInternalNumber': _localInternalNumber(),
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
        label: 'مرشّح ICE ($type)',
      ));
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _rtc.showRemoteStream(remoteRenderer, event.streams.first);
        _safeNotify();
      }
    };
    pc.onIceGatheringState = (state) {
      _logDiagnostic('حالة تجميع ICE: ${state.name}');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        final counts =
            _localCandidateCounts.entries.map((e) => '${e.key}=${e.value}').join('، ');
        _logDiagnostic('اكتمل تجميع ICE — المرشّحات المحلية: ${counts.isEmpty ? "لا شيء" : counts}');
        if ((_localCandidateCounts['relay'] ?? 0) == 0) {
          // لا مرشّح relay إطلاقًا = خادم TURN لم يُنتِج مرشّحًا على هذه
          // الشبكة (محجوب/بيانات اعتماد/انقطاع). الاتصال المباشر قد ينجح
          // على شبكة محلية أو NAT متساهل، لكن خلف CGNAT (بيانات الجوال
          // غالبًا) سيفشل — هذا السطر هو أول مكان يُنظَر إليه عند فشل
          // مكالمة بين شبكتين مختلفتين.
          _logDiagnostic(
              'تحذير: لا يوجد أي مرشّح relay — خادم TURN غير متاح من هذه الشبكة؛ الاتصال خلف NAT مقيَّد/CGNAT سيفشل غالبًا');
        }
      }
    };
    pc.onIceConnectionState = (state) {
      _logDiagnostic('حالة اتصال ICE: ${state.name}');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _reconnectGraceTimer?.cancel();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        // بعض المنصّات/الإصدارات لا ترفع onConnectionState=Failed بموثوقية
        // لكنها ترفع حالة ICE — هذا هو مسار الفشل المضمون على كل حال.
        _handleConnectionTrouble(call, pc);
      }
    };
    pc.onSignalingState = (state) => _logDiagnostic('حالة التفاوض (signaling): ${state.name}');
    pc.onConnectionState = (state) {
      _lastConnectionState = state;
      _logDiagnostic('حالة الاتصال الكلية: ${state.name}');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _reconnectGraceTimer?.cancel();
        final startedAt = _callAttemptStartedAt;
        if (startedAt != null) {
          _logDiagnostic(
              'تأسّس اتصال WebRTC بعد ${DateTime.now().difference(startedAt).inMilliseconds / 1000.0} ثانية من بدء المحاولة');
        }
        unawaited(_logSelectedCandidatePair(pc));
        if (call.state != CallState.active) {
          call.state = CallState.active;
          call.connectedAt = DateTime.now();
          _safeNotify();
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _handleConnectionTrouble(call, pc);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (call.connectedAt == null) {
          // قبل أول اتصال ناجح، disconnected عابر شائع أثناء فحص المرشّحات
          // المتعاقبة — ليس فشلًا بحد ذاته؛ النتيجة النهائية تأتي عبر
          // Connected أو Failed. التعامل معه كفشل هنا كان يُجهض تفاوضًا
          // سليمًا بمحاولة restart غير لازمة.
          _logDiagnostic('ICE disconnected قبل اكتمال التأسيس — عابر غالبًا أثناء فحص المرشّحات، بانتظار النتيجة');
          return;
        }
        _handleConnectionTrouble(call, pc);
      }
    };
  }

  /// يسجّل زوج المرشّحين الذي اختاره ICE فعليًا عند نجاح الاتصال (محلي/
  /// بعيد، النوع والبروتوكول) — هذا يجاوب مباشرة "هل نجح الاتصال مباشرةً
  /// (host/srflx) أم عبر ترحيل TURN (relay)؟" وهو التمييز الحاسم في تشخيص
  /// فشل المكالمات بين شبكتين مختلفتين. أفضل-جهد: أي فشل في قراءة
  /// الإحصاءات يُسجَّل ولا يؤثر على المكالمة نفسها.
  Future<void> _logSelectedCandidatePair(RTCPeerConnection pc) async {
    try {
      final stats = await pc.getStats();
      final byId = {for (final report in stats) report.id: report.values};
      String? selectedPairId;
      for (final report in stats) {
        if (report.type == 'transport') {
          selectedPairId = report.values['selectedCandidatePairId'] as String?;
        }
      }
      Map<dynamic, dynamic>? pair = selectedPairId == null ? null : byId[selectedPairId];
      if (pair == null) {
        for (final report in stats) {
          if (report.type == 'candidate-pair' &&
              report.values['nominated'] == true &&
              report.values['state'] == 'succeeded') {
            pair = report.values;
            break;
          }
        }
      }
      if (pair == null) {
        _logDiagnostic('تعذّر تحديد زوج المرشّحين المختار من إحصاءات WebRTC');
        return;
      }
      String describe(Map<dynamic, dynamic>? candidate) {
        if (candidate == null) return '?';
        final type = candidate['candidateType'] ?? '?';
        final protocol = candidate['protocol'] ?? candidate['transport'] ?? '?';
        return '$type/$protocol';
      }

      final local = describe(byId[pair['localCandidateId']]);
      final remote = describe(byId[pair['remoteCandidateId']]);
      _logDiagnostic('زوج المرشّحين المختار: محلي $local ↔ بعيد $remote');
      if (local.startsWith('relay') || remote.startsWith('relay')) {
        _logDiagnostic('الوسائط تمر عبر ترحيل TURN — الاتصال المباشر كان مستحيلًا بين هاتين الشبكتين (متوقَّع خلف CGNAT)');
      }
    } catch (error) {
      _logDiagnostic('تعذّرت قراءة إحصاءات WebRTC: $error');
    }
  }

  /// معالجة موحَّدة لمشاكل اتصال WebRTC، بحالتين مختلفتين جوهريًا:
  ///
  /// **1) فشل التأسيس الأولي (connectedAt == null):** المكالمة قُبِلت
  /// (حالة connecting) لكن ICE لم يستطع إيجاد أي زوج مرشّحين عامل — الصورة
  /// النموذجية لمكالمة بين شبكتين مختلفتين خلف NAT مقيَّد/CGNAT حين لا
  /// ينجح hole punching ولا يتوفّر مرشّح TURN relay عامل. قبل هذا المسار
  /// لم يكن هناك أي معالجة لهذه الحالة إطلاقًا (القيد القديم "لا يعمل إلا
  /// بعد active")، فتبقى المكالمة "جارٍ الاتصال..." بلا نهاية بعد الضغط
  /// على قبول — بالضبط العطل المُبلَّغ عنه. الآن: محاولة ICE restart واحدة
  /// (تلتقط مرشّحات جديدة، مثل مسار TURN عبر TCP/443 إن كانت UDP محجوبة
  /// عند أول محاولة)، ثم مهلة 15 ثانية، ثم إنهاء واضح بسبب مُسجَّل — مع
  /// إبلاغ الطرف الآخر كي لا يبقى هو أيضًا عالقًا.
  ///
  /// **2) انقطاع بعد اتصال ناجح (connectedAt != null):** تذبذب شبكة أو
  /// تبديل Wi-Fi↔بيانات جوال — نفس الآلية (restart + مهلة) لاستعادة
  /// المكالمة بدل إنهائها عند أول تعثّر.
  ///
  /// **قيد أمان صريح يبقى ساريًا:** لا يعمل هذا إطلاقًا أثناء ringing —
  /// تغيّر الشبكة وحده يجب ألا "يُكمل" اتصال مكالمة لم يوافَق عليها بعد؛
  /// تلك تُترَك لمهلة الرنين العادية (45 ثانية).
  void _handleConnectionTrouble(CallSession call, RTCPeerConnection pc) {
    if (currentCall != call) return;
    if (call.connectedAt == null && call.state != CallState.connecting) return;
    // حدثا ICE/Connection قد يرفعان Failed معًا — مؤقّت واحد يكفي.
    if (_reconnectGraceTimer?.isActive ?? false) return;

    final initialFailure = call.connectedAt == null;
    _logDiagnostic(initialFailure
        ? 'فشل تأسيس اتصال ICE الأولي — محاولة ICE restart (قد يلتقط مسار TURN بديلًا)...'
        : 'انقطاع اتصال — محاولة استعادة (ICE restart)...');
    if (!initialFailure && call.state == CallState.active) {
      // يُعلِم الواجهة لعرض «جاري إعادة الاتصال…» بدل بقاء العداد وكأن شيئًا
      // لم يحدث، أو إنهاء المكالمة عند أول تعثّر عابر.
      call.state = CallState.reconnecting;
      _safeNotify();
    }
    try {
      pc.restartIce();
    } catch (error) {
      _logDiagnostic('restartIce فشل أو غير مدعوم: $error');
    }
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = Timer(_reconnectGrace, () {
      if (currentCall == call &&
          _lastConnectionState != RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (initialFailure) {
          _logDiagnostic('فشل تأسيس الاتصال نهائيًا بعد ICE restart — راجع ملخّص المرشّحات/تحذير TURN أعلاه');
          unawaited(_endCall(
            reason: 'فشل إنشاء اتصال WebRTC بين الشبكتين — راجع مرشّحات ICE/خادم TURN في سجل الأخطاء',
            notifyPeer: true,
          ));
        } else {
          _logDiagnostic('تعذّرت استعادة الاتصال خلال ${_reconnectGrace.inSeconds} ثانية — إنهاء المكالمة');
          unawaited(_endCall(reason: 'انقطع الاتصال', notifyPeer: false));
        }
      }
    });
  }

  void _startRingTimeout() {
    _ringTimer?.cancel();
    _ringTimer = Timer(_ringTimeout, () {
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
    _reconnectGraceTimer?.cancel();
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
    _logDiagnostic('تنظيف موارد المكالمة (cleanup) — السبب: ${reason ?? "إنهاء عادي"}');
    await _cleanupCallResources();

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

  /// المسار الموحَّد الوحيد لتحرير كل موارد المكالمة — يُستدعى من _endCall
  /// (وبالتبعية من كل مسارات الإنهاء: hang up، رفض، انتهاء مهلة، فشل
  /// اتصال، ICE فشل، إغلاق الشاشة يدويًا) ومن dispose(). آمن للاستدعاء
  /// أكثر من مرة (idempotent) — كل خطوة تتحقق أولًا أنها لم تُنفَّذ بعد
  /// (المتغيرات تُصفَّر فور استخدامها) فلا يحدث أي خطأ أو عمل مكرَّر لو
  /// استُدعيت مرتين متتاليتين.
  Future<void> _cleanupCallResources() async {
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    _pendingOfferSdp = null;
    _callAttemptStartedAt = null;
    _localCandidateCounts.clear();
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
      // إيقاف المسارات يحرّر الميكروفون/الكاميرا، وتحرير التيار نفسه يكمل
      // إطلاق موارده على مستوى المنصّة (لا يبقى أي MediaStream عالق).
      try {
        await stream.dispose();
      } catch (_) {
        // لا شيء — تنظيف أفضل-جهد؛ المسارات أُوقفت فعلًا أعلاه.
      }
    }

    // خطوتان منفصلتان ضروريتان معًا لتحرير الميكروفون فعليًا من منظور بقية
    // النظام (تطبيقات أخرى، أو حتى ميزة "رسالة صوتية" في هذا التطبيق نفسه):
    // 1) setSpeakerphoneOn(false): يعيد مسار الصوت (سمّاعة خارجية/داخلية).
    // 2) clearAndroidCommunicationDevice(): يُصرِّح لأندرويد أن "جهاز
    //    الاتصال النشط" (Communication Device) لم يعد مطلوبًا — بدون هذا
    //    تحديدًا، إيقاف المسارات وحده (getTracks/stop أعلاه) لا يكفي؛
    //    يبقى أندرويد يعتبر التطبيق "في جلسة اتصال" على مستوى النظام،
    //    فتفشل أو تُسجَّل فارغة أي محاولة تسجيل صوت لاحقة (حتى من تطبيق
    //    آخر تمامًا) حتى تنتهي هذه الجلسة العالقة صراحة. هذا التابع
    //    موثَّق رسميًا في flutter_webrtc لهذا الغرض بالضبط: "After Android
    //    app finishes a session, on audio focus loss, clear the active
    //    communication device."
    try {
      await _rtc.setSpeakerphoneOn(false);
    } catch (_) {
      // لا شيء — تحسين إضافي، ليس شرطًا لإنهاء المكالمة بنجاح.
    }
    try {
      await _rtc.clearAndroidCommunicationDevice();
    } catch (_) {
      // لا شيء — منصّات غير أندرويد لا تدعم هذا الاستدعاء أصلًا.
    }

    isSpeakerOn = false;
    isMuted = false;
    // ضبط srcObject على مُصيِّر لم يُهيَّأ بعد (initialize()) يرمي استثناءً —
    // يحدث هذا فعليًا عند dispose لتطبيق لم تُجرَ فيه أي مكالمة إطلاقًا قط.
    if (_renderersInitialized) {
      _rtc.showLocalStream(localRenderer, null);
      _rtc.showRemoteStream(remoteRenderer, null);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ringTimer?.cancel();
    _clearTimer?.cancel();
    _videoUpgradeTimer?.cancel();
    _reconnectGraceTimer?.cancel();
    unawaited(_cleanupCallResources());
    unawaited(_rtc.disposeRenderers(localRenderer, remoteRenderer));
    super.dispose();
  }
}
