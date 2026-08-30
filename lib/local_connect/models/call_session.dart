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

  /// قابل للتغيير: مكالمة صوتية جارية قد تتحول لفيديو أثناء الاتصال (راجع
  /// CallService.requestVideoUpgrade) دون إنهائها وبدء مكالمة جديدة.
  CallMediaType mediaType;
  final DateTime startedAt;

  CallState state = CallState.ringing;
  DateTime? connectedAt;

  /// سبب الانتهاء لعرضه للمستخدم بعد إغلاق المكالمة مباشرة (رُفضت، انتهت
  /// بلا رد، فشل الاتصال...). null إن انتهت بشكل طبيعي بإنهاء أحد الطرفين.
  String? endReason;

  /// true لدى الطرف الذي طلب التحويل لفيديو، بانتظار رد الطرف الآخر —
  /// يُستخدَم لعرض "بانتظار الموافقة..." وتعطيل زر الفيديو حتى يصل الرد.
  bool pendingOutgoingVideoUpgrade = false;

  /// true لدى الطرف الذي وصله طلب تحويل لفيديو، بانتظار رده هو —
  /// يُستخدَم لعرض شاشة/بانر "فلان يطلب التحويل لفيديو" بزرَي قبول/رفض.
  bool pendingIncomingVideoUpgrade = false;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);
}
