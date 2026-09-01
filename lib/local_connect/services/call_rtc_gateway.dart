import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

/// بوابة ضيّقة لكل ما تلمسه [CallService] خارج Dart الخالص (flutter_webrtc
/// والقنوات الأصلية): إنشاء اتصال WebRTC، التقاط الوسائط، ربط المُصيِّرات،
/// ومسار الصوت على أندرويد.
///
/// الغرض الوحيد من هذا التجريد هو جعل منطق دورة حياة المكالمة (قبول/رفض/
/// إنهاء/فشل ICE/إعادة اتصال/تنظيف الموارد) قابلًا لاختبار regression كامل
/// في flutter_test ببديل وهمي ([FakeCallRtcGateway] في الاختبارات)، دون
/// الحاجة لمنصّة WebRTC حقيقية لا تتوفر تحت flutter_tester. الافتراضي
/// [FlutterWebRtcGateway] هو نفس الاستدعاءات المباشرة السابقة حرفيًا —
/// لا تغيير سلوكي في الإنتاج إطلاقًا.
abstract class CallRtcGateway {
  /// يهيّئ مُصيِّرَي الفيديو (يُستدعى مرة واحدة قبل أول استخدام).
  Future<void> initializeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote);

  /// يُنهي المُصيِّرَين نهائيًا (من dispose الخدمة).
  Future<void> disposeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote);

  /// يطلب صلاحيات الميكروفون (والكاميرا عند [video]) — يرمي عند الرفض.
  Future<void> ensureMediaPermissions({required bool video});

  /// يلتقط الوسائط المحلية: صوت دائمًا + كاميرا عند [video].
  Future<MediaStream> getUserMedia({required bool video});

  /// يلتقط الكاميرا فقط (لإضافة الفيديو لمكالمة صوتية جارية عند التحويل).
  Future<MediaStream> getCameraStream();

  /// يُسمَّى createConnection (لا createPeerConnection) عمدًا — لو طابق اسم
  /// الدالة العامة في flutter_webrtc لاستدعى التنفيذُ نفسَه ذاتيًا بلا نهاية
  /// داخل نطاق الصنف.
  Future<RTCPeerConnection> createConnection(Map<String, dynamic> configuration);

  /// يربط/يفصل (null) تيارًا محليًا عن مُصيِّر المعاينة.
  void showLocalStream(RTCVideoRenderer renderer, MediaStream? stream);

  /// يربط/يفصل (null) تيار الطرف الآخر عن مُصيِّر العرض.
  void showRemoteStream(RTCVideoRenderer renderer, MediaStream? stream);

  Future<void> setSpeakerphoneOn(bool enabled);

  /// يُصرِّح لأندرويد بإنهاء "جلسة الاتصال" على مستوى النظام — بدونه يبقى
  /// الميكروفون محجوزًا للتطبيقات الأخرى حتى بعد إيقاف المسارات (راجع
  /// توثيق CallService._cleanupCallResources).
  Future<void> clearAndroidCommunicationDevice();

  Future<void> switchCamera(MediaStreamTrack track);
}

/// التنفيذ الحقيقي فوق flutter_webrtc — الاستدعاءات نفسها التي كانت مباشرة
/// داخل CallService قبل استخراج هذه البوابة.
class FlutterWebRtcGateway implements CallRtcGateway {
  @override
  Future<void> initializeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote) async {
    await local.initialize();
    await remote.initialize();
  }

  @override
  Future<void> disposeRenderers(RTCVideoRenderer local, RTCVideoRenderer remote) async {
    await local.dispose();
    await remote.dispose();
  }

  @override
  Future<void> ensureMediaPermissions({required bool video}) async {
    final permissions = <Permission>[Permission.microphone, if (video) Permission.camera];
    final statuses = await permissions.request();
    if (statuses.values.any((status) => !status.isGranted)) {
      throw 'صلاحية الميكروفون${video ? '/الكاميرا' : ''} مرفوضة';
    }
  }

  @override
  Future<MediaStream> getUserMedia({required bool video}) => navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video ? {'facingMode': 'user'} : false,
      });

  @override
  Future<MediaStream> getCameraStream() => navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });

  @override
  Future<RTCPeerConnection> createConnection(Map<String, dynamic> configuration) =>
      createPeerConnection(configuration);

  @override
  void showLocalStream(RTCVideoRenderer renderer, MediaStream? stream) {
    renderer.srcObject = stream;
  }

  @override
  void showRemoteStream(RTCVideoRenderer renderer, MediaStream? stream) {
    renderer.srcObject = stream;
  }

  @override
  Future<void> setSpeakerphoneOn(bool enabled) => Helper.setSpeakerphoneOn(enabled);

  @override
  Future<void> clearAndroidCommunicationDevice() => Helper.clearAndroidCommunicationDevice();

  @override
  Future<void> switchCamera(MediaStreamTrack track) => Helper.switchCamera(track);
}
