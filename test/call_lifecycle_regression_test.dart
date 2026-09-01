import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:local_connect/local_connect/models/call_session.dart';
import 'package:local_connect/local_connect/services/call_rtc_gateway.dart';
import 'package:local_connect/local_connect/services/call_service.dart';

// ---------------------------------------------------------------------------
// بدائل وهمية لطبقة flutter_webrtc — تتيح اختبار دورة حياة المكالمة كاملة
// (قبول/رفض/إنهاء/فشل ICE/إعادة اتصال) دون منصّة WebRTC حقيقية، مع تسجيل
// دقيق لما حدث للموارد: إغلاق PeerConnection، إيقاف المسارات، تحرير التيار،
// مسار الصوت، وجلسة الاتصال على مستوى النظام.
// ---------------------------------------------------------------------------

class _FakeRtpSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaTrack implements MediaStreamTrack {
  _FakeMediaTrack(this.kind);

  @override
  final String kind;

  bool _enabled = true;
  int stopCount = 0;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) => _enabled = value;

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaStream implements MediaStream {
  final tracks = <_FakeMediaTrack>[];
  int disposeCount = 0;

  @override
  List<MediaStreamTrack> getTracks() => tracks;

  @override
  List<MediaStreamTrack> getAudioTracks() => tracks.where((t) => t.kind == 'audio').toList();

  @override
  List<MediaStreamTrack> getVideoTracks() => tracks.where((t) => t.kind == 'video').toList();

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) async {
    tracks.add(track as _FakeMediaTrack);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePeerConnection implements RTCPeerConnection {
  int closeCount = 0;
  int restartCount = 0;
  final addedTracks = <MediaStreamTrack>[];
  RTCSessionDescription? localDescription;
  RTCSessionDescription? remoteDescription;

  @override
  Function(RTCIceCandidate candidate)? onIceCandidate;
  @override
  Function(RTCIceGatheringState state)? onIceGatheringState;
  @override
  Function(RTCIceConnectionState state)? onIceConnectionState;
  @override
  Function(RTCPeerConnectionState state)? onConnectionState;
  @override
  Function(RTCSignalingState state)? onSignalingState;
  @override
  Function(RTCTrackEvent event)? onTrack;

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic> constraints = const {}]) async =>
      RTCSessionDescription('fake-offer-sdp', 'offer');

  @override
  Future<RTCSessionDescription> createAnswer([Map<String, dynamic> constraints = const {}]) async =>
      RTCSessionDescription('fake-answer-sdp', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async =>
      localDescription = description;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async =>
      remoteDescription = description;

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track, [MediaStream? stream]) async {
    addedTracks.add(track);
    return _FakeRtpSender();
  }

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];

  @override
  Future<void> restartIce() async {
    restartCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  // محاكاة أحداث WebRTC من الاختبار:
  void emitConnectionState(RTCPeerConnectionState state) => onConnectionState?.call(state);

  void emitIceConnectionState(RTCIceConnectionState state) => onIceConnectionState?.call(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCallRtcGateway implements CallRtcGateway {
  int rendererInitCount = 0;
  int rendererDisposeCount = 0;
  int permissionRequests = 0;
  int userMediaCount = 0;
  final streams = <_FakeMediaStream>[];
  final connections = <_FakePeerConnection>[];
  final speakerStates = <bool>[];
  int commDeviceClearCount = 0;
  final localShown = <MediaStream?>[];
  final remoteShown = <MediaStream?>[];

  _FakePeerConnection get pc => connections.last;

  @override
  Future<void> initializeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote) async {
    rendererInitCount++;
  }

  @override
  Future<void> disposeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote) async {
    rendererDisposeCount++;
  }

  @override
  Future<void> ensureMediaPermissions({required bool video}) async {
    permissionRequests++;
  }

  @override
  Future<MediaStream> getUserMedia({required bool video}) async {
    userMediaCount++;
    final stream = _FakeMediaStream()..tracks.add(_FakeMediaTrack('audio'));
    if (video) stream.tracks.add(_FakeMediaTrack('video'));
    streams.add(stream);
    return stream;
  }

  @override
  Future<MediaStream> getCameraStream() async {
    final stream = _FakeMediaStream()..tracks.add(_FakeMediaTrack('video'));
    streams.add(stream);
    return stream;
  }

  @override
  Future<RTCPeerConnection> createConnection(Map<String, dynamic> configuration) async {
    final pc = _FakePeerConnection();
    connections.add(pc);
    return pc;
  }

  @override
  void showLocalStream(RTCVideoRenderer renderer, MediaStream? stream) => localShown.add(stream);

  @override
  void showRemoteStream(RTCVideoRenderer renderer, MediaStream? stream) => remoteShown.add(stream);

  @override
  Future<void> setSpeakerphoneOn(bool enabled) async => speakerStates.add(enabled);

  @override
  Future<void> clearAndroidCommunicationDevice() async => commDeviceClearCount++;

  @override
  Future<void> switchCamera(MediaStreamTrack track) async {}
}

// ---------------------------------------------------------------------------

/// يتحقق من عقد الـregression الكامل: بعد انتهاء أي مكالمة — أيًا كان سبب
/// الانتهاء — يجب أن يتحقق كل هذا دفعة واحدة: PeerConnection مُغلَق، كل
/// المسارات موقوفة، التيار محرَّر، مسار الصوت مُعاد، جلسة الاتصال على مستوى
/// النظام مُخلاة، والحالة ended (أي لا مكالمة عالقة "Ghost").
void expectFullyCleaned(_FakeCallRtcGateway gateway, CallService service, {required _FakePeerConnection pc}) {
  expect(pc.closeCount, greaterThanOrEqualTo(1), reason: 'يجب إغلاق PeerConnection');
  for (final stream in gateway.streams) {
    for (final track in stream.tracks) {
      expect(track.stopCount, 1, reason: 'كل مسار صوت/فيديو يُوقَف مرة واحدة بالضبط');
    }
    expect(stream.disposeCount, 1, reason: 'كل MediaStream يُحرَّر مرة واحدة');
  }
  expect(gateway.speakerStates.last, isFalse, reason: 'مسار الصوت (السمّاعة) يجب أن يُعاد');
  expect(gateway.commDeviceClearCount, greaterThanOrEqualTo(1),
      reason: 'جلسة الاتصال على مستوى النظام (Communication Device) يجب أن تُخلى وإلا بقي الميكروفون محجوزًا');
  expect(gateway.localShown.last, isNull, reason: 'مُصيِّر المعاينة المحلية يجب فصله');
  final call = service.currentCall;
  expect(call == null || call.state == CallState.ended, isTrue,
      reason: 'لا يجوز بقاء مكالمة فعّالة بعد الإنهاء (لا Ghost Call)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCallRtcGateway gateway;
  late List<Map<String, dynamic>> sent;
  late List<String> diagnostics;
  late List<String> missedCalls;
  late CallService service;
  // يتتبّع dispose الصريح داخل بعض الاختبارات حتى لا يُعيد tearDown التخلّص
  // من نفس الخدمة (ChangeNotifier يرمي عند dispose المزدوج).
  var serviceDisposed = false;

  /// إشارة قبول واردة لمكالمة صادرة جارية (يُكمل مسار "الطرف الآخر ردّ").
  Future<void> simulatePeerAccepted() async {
    await service.handleSignal({
      'type': 'call_answer',
      'id': service.currentCall!.callId,
      'senderInternalNumber': service.currentCall!.peerInternalNumber,
      'sdp': 'v=0',
    });
  }

  /// عرض مكالمة وارد صالح وطازج (بختم زمني حديث حتى لا يُرفَض كقديم).
  Map<String, dynamic> incomingOffer({String id = 'call-x'}) => {
        'type': 'call_offer',
        'id': id,
        'senderInternalNumber': 'LC-PEERX',
        'callerDisplayName': 'الطرف س',
        'mediaType': 'audio',
        'sdp': 'v=0',
        'sentAt': DateTime.now().toIso8601String(),
      };

  setUp(() {
    gateway = _FakeCallRtcGateway();
    sent = [];
    diagnostics = [];
    missedCalls = [];
    serviceDisposed = false;
    service = CallService(
      sendSignal: (peer, payload) async {
        sent.add(payload);
        return true;
      },
      localInternalNumber: () => 'LC-LOCAL',
      localDisplayName: () => 'محلي',
      onMissedCall: (number, name, type) => missedCalls.add(number),
      onCallDiagnostic: diagnostics.add,
      rtcGateway: gateway,
      ringTimeout: const Duration(milliseconds: 400),
      reconnectGrace: const Duration(milliseconds: 300),
    );
  });

  tearDown(() {
    if (!serviceDisposed) service.dispose();
  });

  test('إنهاء من الطرف الأول بعد اتصال ناجح: تنظيف كامل + بدء مكالمة جديدة فورًا', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد ١', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    expect(service.currentCall!.state, CallState.active);

    await service.endCall();
    expectFullyCleaned(gateway, service, pc: gateway.pc);
    expect(sent.any((p) => p['type'] == 'call_end'), isTrue,
        reason: 'يجب إبلاغ الطرف الآخر بالإنهاء');

    // مكالمة جديدة فور انتهاء السابقة — يجب ألا تحجبها بطاقة "انتهت
    // المكالمة" المعروضة لثوانٍ.
    await service.startCall(
        peerInternalNumber: 'LC-PEER2', peerDisplayName: 'بعيد ٢', mediaType: CallMediaType.audio);
    expect(service.currentCall, isNotNull);
    expect(service.currentCall!.state, CallState.ringing);
    expect(service.currentCall!.peerInternalNumber, 'LC-PEER2');
  });

  test('إنهاء من الطرف الثاني (call_end وارد) ينظّف كل الموارد', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    await service.handleSignal({
      'type': 'call_end',
      'id': service.currentCall!.callId,
      'senderInternalNumber': 'LC-PEER1',
    });
    expectFullyCleaned(gateway, service, pc: gateway.pc);
    expect(service.currentCall!.endReason, 'أنهى الطرف الآخر المكالمة');
  });

  test('رفض مكالمة واردة: تنظيف كامل دون فتح الميكروفون إطلاقًا', () async {
    await service.handleSignal(incomingOffer());
    expect(service.currentCall!.state, CallState.ringing);

    await service.rejectCall();
    expect(gateway.userMediaCount, 0, reason: 'الرفض يجب ألا يفتح الميكروفون/الكاميرا أصلًا');
    expect(gateway.connections, isEmpty, reason: 'الرفض يجب ألا ينشئ PeerConnection أصلًا');
    expect(service.currentCall!.state, CallState.ended);
    expect(missedCalls, isEmpty, reason: 'الرفض الصريح ليس مكالمة فائتة');
    expect(sent.any((p) => p['type'] == 'call_reject'), isTrue);
  });

  test('عدم الرد: مهلة الرنين تنهي المكالمة وتُسجَّل فائتة وتُنظَّف الموارد', () async {
    await service.handleSignal(incomingOffer());
    expect(service.currentCall!.state, CallState.ringing);

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(service.currentCall!.state, CallState.ended);
    expect(service.currentCall!.endReason, 'لا يوجد رد');
    expect(missedCalls, ['LC-PEERX']);
    // لا وسائط فُتحت أصلًا، لكن جلسة النظام تُخلى على كل حال دون أخطاء.
    expect(gateway.userMediaCount, 0);
  });

  test('فشل إيصال call_offer (لا مسار شبكة): إنهاء فوري واضح بلا انتظار', () async {
    service.dispose();
    serviceDisposed = true;
    service = CallService(
      sendSignal: (peer, payload) async => false, // لا مسار تسليم إطلاقًا
      localInternalNumber: () => 'LC-LOCAL',
      localDisplayName: () => 'محلي',
      onCallDiagnostic: diagnostics.add,
      rtcGateway: gateway,
      ringTimeout: const Duration(milliseconds: 400),
      reconnectGrace: const Duration(milliseconds: 300),
    );

    await service.startCall(
        peerInternalNumber: 'LC-DOWN', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    expect(service.currentCall!.state, CallState.ended);
    expect(service.currentCall!.endReason, contains('تعذّر الوصول'));
    expectFullyCleaned(gateway, service, pc: gateway.pc);
  });

  test('فشل ICE قبل أول اتصال (بين شبكتين/CGNAT): restart ثم إنهاء واضح مُبلَّغ للطرفين', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    expect(service.currentCall!.state, CallState.connecting);

    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    expect(gateway.pc.restartCount, 1, reason: 'يُحاوَل ICE restart قبل الاستسلام');

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(service.currentCall!.state, CallState.ended);
    expect(service.currentCall!.endReason, contains('WebRTC'));
    expect(sent.any((p) => p['type'] == 'call_end'), isTrue,
        reason: 'فشل التأسيس يجب أن يُنهي المكالمة لدى الطرفين كي لا يعلَق الآخر');
    expectFullyCleaned(gateway, service, pc: gateway.pc);
  });

  test('فشل ICE عبر onIceConnectionState (منصّات لا ترفع connectionState) يُعالَج أيضًا', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();

    gateway.pc.emitIceConnectionState(RTCIceConnectionState.RTCIceConnectionStateFailed);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(service.currentCall!.state, CallState.ended);
    expectFullyCleaned(gateway, service, pc: gateway.pc);
  });

  test('انقطاع بعد اتصال قائم ثم عودة الشبكة: reconnecting ← active دون إنهاء المكالمة', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    // انقطاع عابر (تبديل Wi-Fi↔بيانات جوال مثلًا) — لا يجب أن تنتهي المكالمة.
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
    expect(service.currentCall!.state, CallState.reconnecting,
        reason: 'تُعرَض «جاري إعادة الاتصال…» أثناء محاولة الاستعادة');
    expect(gateway.pc.restartCount, 1);

    // عودة الشبكة: نفس المكالمة تستمر.
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    await Future<void>.delayed(const Duration(milliseconds: 500)); // تتجاوز مهلة الاستعادة
    expect(service.currentCall!.state, CallState.active);
    expect(gateway.pc.closeCount, 0, reason: 'المكالمة الناجية لا تُغلَق ولا تُنظَّف');
  });

  test('انقطاع بعد اتصال قائم دون عودة: إنهاء بعد المهلة وتنظيف كامل', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(service.currentCall!.state, CallState.ended);
    expect(service.currentCall!.endReason, 'انقطع الاتصال');
    expectFullyCleaned(gateway, service, pc: gateway.pc);
  });

  test('مكالمة فيديو: إيقاف مسار الكاميرا مع الصوت عند الإنهاء', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.video);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    await service.endCall();
    expectFullyCleaned(gateway, service, pc: gateway.pc);
    final stream = gateway.streams.first;
    expect((stream.getVideoTracks().single as _FakeMediaTrack).stopCount, 1,
        reason: 'مسار الكاميرا يُوقَف مع الصوت');
  });

  test('قبول مكالمة واردة ثم فشل التأسيس: تنظيف كامل وإنهاء مُبلَّغ', () async {
    await service.handleSignal(incomingOffer());
    await service.acceptCall();
    expect(service.currentCall!.state, CallState.connecting);
    expect(sent.any((p) => p['type'] == 'call_answer'), isTrue);

    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(service.currentCall!.state, CallState.ended);
    expectFullyCleaned(gateway, service, pc: gateway.pc);
  });

  test('الإنهاء المزدوج (endCall مرتين) آمن: لا إغلاق مكرَّر ولا أخطاء (idempotent)', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    await service.endCall();
    await service.endCall();
    expect(gateway.pc.closeCount, 1, reason: 'PeerConnection يُغلَق مرة واحدة مهما تكرر الإنهاء');
    for (final track in gateway.streams.first.tracks) {
      expect(track.stopCount, 1, reason: 'كل مسار يُوقَف مرة واحدة مهما تكرر الإنهاء');
    }
  });

  test('dispose أثناء مكالمة نشطة ينظّف كل الموارد أيضًا', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    service.dispose();
    serviceDisposed = true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(gateway.pc.closeCount, greaterThanOrEqualTo(1));
    for (final track in gateway.streams.first.tracks) {
      expect(track.stopCount, 1);
    }
    expect(gateway.rendererDisposeCount, 1);
  });

  test('عرض وارد أثناء مكالمة قائمة: رفض مشغول تلقائي دون لمس الوسائط أو المكالمة القائمة', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);

    await service.handleSignal(incomingOffer(id: 'call-intruder'));
    expect(sent.any((p) => p['type'] == 'call_reject' && p['reason'] == 'busy'), isTrue);
    expect(service.currentCall!.state, CallState.active,
        reason: 'المكالمة القائمة لا تتأثر بالعرض المرفوض');
    expect(gateway.connections.length, 1, reason: 'لا PeerConnection ثاني للعرض المرفوض');
    expect(gateway.userMediaCount, 1, reason: 'لا فتح ميكروفون ثانٍ للعرض المرفوض');
  });

  test('السجل التشخيصي يغطّي مراحل دورة الحياة (قبول/ICE/اتصال/إنهاء)', () async {
    await service.startCall(
        peerInternalNumber: 'LC-PEER1', peerDisplayName: 'بعيد', mediaType: CallMediaType.audio);
    await simulatePeerAccepted();
    gateway.pc.emitConnectionState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    await service.endCall();

    expect(diagnostics.any((d) => d.contains('بدء مكالمة صادرة')), isTrue);
    expect(diagnostics.any((d) => d.contains('وصل call_answer')), isTrue);
    expect(diagnostics.any((d) => d.contains('حالة الاتصال الكلية')), isTrue);
    expect(diagnostics.any((d) => d.contains('تنظيف موارد المكالمة')), isTrue);
  });
}
