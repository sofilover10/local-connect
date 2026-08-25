/// من بدأ المكالمة: نحن (outgoing) أم الطرف الآخر (incoming).
enum CallDirection { outgoing, incoming }

enum CallMediaType { audio, video }

/// دورة حياة المكالمة:
/// ringing → connecting (بعد قبولها، قبل اكتمال تفاوض WebRTC) → active
/// (صوت/فيديو يتدفّق فعليًا) → ended.
enum CallState { ringing, connecting, active, ended }

/// حالة مكالمة واحدة جارية أو منتهية للتوّ — تُعرَض في الواجهة عبر
/// [CallService.currentCall].
class CallSession {
  CallSession({
    required this.callId,
    required this.peerInternalNumber,
    required this.peerDisplayName,
    required this.direction,
    required this.mediaType,
  }) : startedAt = DateTime.now();

  final String callId;
  final String peerInternalNumber;
  final String peerDisplayName;
  final CallDirection direction;
  final CallMediaType mediaType;
  final DateTime startedAt;

  CallState state = CallState.ringing;
  DateTime? connectedAt;

  /// سبب الانتهاء لعرضه للمستخدم بعد إغلاق المكالمة مباشرة (رُفضت، انتهت
  /// بلا رد، فشل الاتصال...). null إن انتهت بشكل طبيعي بإنهاء أحد الطرفين.
  String? endReason;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);
}
