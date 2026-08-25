import 'package:flutter/services.dart';

/// إشعار نظام أندرويد لرسالة واردة — ضروري لأن خدمة الخلفية تُبقي التطبيق
/// يستقبل الرسائل بصمت حتى وشاشته مغلقة؛ بدون إشعار صريح هنا، لن يعرف
/// المستخدم أن رسالة وصلت أصلًا قبل أن يفتح التطبيق يدويًا بنفسه.
class MessageNotificationService {
  static const _channel = MethodChannel('local_connect/notifications');

  Future<void> showMessageNotification({
    required String conversationId,
    required String senderName,
    required String preview,
  }) =>
      _invoke('showMessageNotification', {
        'conversationId': conversationId,
        'senderName': senderName,
        'preview': preview,
      });

  Future<void> cancelMessageNotification(String conversationId) =>
      _invoke('cancelMessageNotification', {'conversationId': conversationId});

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (_) {
      // لا شيء — لا يجب أن يُسقِط فشل إشعار تجميلي معالجة الرسالة نفسها.
    }
  }
}
