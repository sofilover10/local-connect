import 'package:flutter/services.dart';

/// يشغّل نغمة الرنين الحقيقية (الافتراضية على الجهاز) للمكالمات الواردة،
/// ونغمة طنين انتظار للمكالمات الصادرة، عبر قناة أصلية أندرويد — لا توجد
/// حزمة Flutter لهذا في المشروع ولا أصل صوتي (asset) مُرفَق. الفشل هنا (مثلًا
/// لا نغمة افتراضية على الجهاز) يُتجاهَل بصمت؛ الصوت تحسين، وليس شرطًا
/// لعمل المكالمة نفسها.
class CallSoundService {
  static const _channel = MethodChannel('local_connect/ringtone');

  Future<void> playRingtone() => _invoke('playRingtone');
  Future<void> stopRingtone() => _invoke('stopRingtone');
  Future<void> playRingback() => _invoke('playRingback');
  Future<void> stopRingback() => _invoke('stopRingback');

  /// إشعار بأعلى أولوية مع نيّة "شاشة كاملة" — يظهر اسم المتصل فورًا فوق
  /// شاشة القفل، حتى لو كانت الشاشة مطفأة أو التطبيق غير مفتوح إطلاقًا وقت
  /// الاتصال؛ بدونه، صوت الرنين وحده لا يخبر المستخدم مين المتصل قبل أن
  /// يفتح التطبيق بنفسه يدويًا.
  Future<void> showIncomingCallNotification(String callerName) =>
      _invoke('showIncomingCallNotification', {'callerName': callerName});
  Future<void> cancelIncomingCallNotification() => _invoke('cancelIncomingCallNotification');

  /// يتحقق (ويطلب إن لزم عبر شاشة إعدادات النظام) صلاحية أندرويد 14+
  /// الخاصة بعرض إشعارات الشاشة الكاملة فعليًا فوق شاشة القفل — بدونها،
  /// إشعار المكالمة الواردة يُخفَّض بصمت لإشعار عادي رغم عمل الرنين بشكل
  /// طبيعي. يُستدعى مرة واحدة من [AppState.ensureNotificationPermission].
  Future<void> ensureFullScreenIntentPermission() => _invoke('ensureFullScreenIntentPermission');

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (_) {
      // لا شيء — منصّات أخرى غير أندرويد (أو أجهزة بلا نغمة افتراضية) تفشل
      // هنا بصمت، ويبقى الاهتزاز والنبض البصري كافيَين كمؤشر.
    }
  }
}
