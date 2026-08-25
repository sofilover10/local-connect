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

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod(method);
    } catch (_) {
      // لا شيء — منصّات أخرى غير أندرويد (أو أجهزة بلا نغمة افتراضية) تفشل
      // هنا بصمت، ويبقى الاهتزاز والنبض البصري كافيَين كمؤشر.
    }
  }
}
