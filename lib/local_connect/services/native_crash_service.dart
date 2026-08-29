import 'package:flutter/services.dart';

/// يقرأ أي عطل أصلي (native) التقطه CrashReporter.kt قبل أن تُقتَل العملية
/// في الجلسة السابقة — راجع توثيق CrashReporter.kt لسبب وجود هذا: أعطال
/// الخيوط الأصلية (WebRTC، البلوتوث/Wi-Fi Direct المكتوبَين يدويًا هنا) لا
/// تصل أبدًا لمعالجات أخطاء Dart، فتظل بلا أي سجل رغم أن أندرويد/سامسونج
/// يكتشفانها كـ"تعطّلات متكررة" بلا تفاصيل تصل للمطوّر.
class NativeCrashService {
  static const _channel = MethodChannel('local_connect/crash_log');

  /// يعيد نص آخر عطل أصلي مسجَّل (إن وُجد)، أو null إن لم يحدث أي عطل منذ
  /// آخر مسح. لا يرمي استثناءً عند الفشل (مثلًا على منصّة غير أندرويد).
  Future<String?> readPendingCrash() async {
    try {
      return await _channel.invokeMethod<String>('getPendingCrash');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// يُستدعى بعد قراءة العطل وعرضه في سجل الأخطاء، حتى لا يتكرر عرضه كل إقلاع.
  Future<void> clearPendingCrash() async {
    try {
      await _channel.invokeMethod<void>('clearPendingCrash');
    } on PlatformException {
      // لا شيء — تنظيف غير حرج.
    } on MissingPluginException {
      // لا شيء.
    }
  }
}
