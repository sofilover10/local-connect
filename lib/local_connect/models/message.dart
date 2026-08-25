enum MessageStatus { queued, sent, delivered, failed }

enum MessageKind { text, file, voice }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderInternalNumber,
    required this.text,
    required this.sentAt,
    this.status = MessageStatus.queued,
    this.outgoing = true,
    this.kind = MessageKind.text,
    this.attachmentFileName,
    this.attachmentMimeType,
    this.attachmentSizeBytes,
    this.attachmentLocalPath,
  });

  final String id;
  final String conversationId;
  final String senderInternalNumber;

  /// النص إن كانت رسالة نصية، أو تعليق/اسم قصير إن كانت مرفقًا.
  final String text;
  final DateTime sentAt;
  MessageStatus status;

  /// true إذا كانت مُرسَلة من هذا الجهاز، false إذا كانت واردة من الطرف الآخر.
  final bool outgoing;

  final MessageKind kind;

  /// بيانات المرفق (ملف أو مقطع صوتي) — فارغة لرسائل النص العادية.
  final String? attachmentFileName;
  final String? attachmentMimeType;
  final int? attachmentSizeBytes;

  /// المسار على تخزين *هذا* الجهاز حيث تُحفَظ بايتات المرفق فعليًا (سواء
  /// كان الملف الأصلي المُرسَل أو نسخة محفوظة محليًا من مرفق وارد).
  String? attachmentLocalPath;

  Map<String, dynamic> toMap() => {
        'id': id,
        'conversationId': conversationId,
        'senderInternalNumber': senderInternalNumber,
        'text': text,
        'sentAt': sentAt.toIso8601String(),
        'status': status.name,
        'outgoing': outgoing,
        'kind': kind.name,
        'attachmentFileName': attachmentFileName,
        'attachmentMimeType': attachmentMimeType,
        'attachmentSizeBytes': attachmentSizeBytes,
        'attachmentLocalPath': attachmentLocalPath,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'] as String,
        conversationId: map['conversationId'] as String,
        senderInternalNumber: map['senderInternalNumber'] as String,
        text: map['text'] as String,
        sentAt: DateTime.parse(map['sentAt'] as String),
        status: MessageStatus.values.byName(map['status'] as String),
        outgoing: map['outgoing'] as bool,
        kind: MessageKind.values.byName(map['kind'] as String? ?? 'text'),
        attachmentFileName: map['attachmentFileName'] as String?,
        attachmentMimeType: map['attachmentMimeType'] as String?,
        attachmentSizeBytes: map['attachmentSizeBytes'] as int?,
        attachmentLocalPath: map['attachmentLocalPath'] as String?,
      );

  /// الحمولة المُرسَلة فعليًا عبر مقبس TCP بين الجهازين. المرفقات تُرسَل
  /// بترميز base64 ضمن نفس سطر JSON — أبسط بكثير من تأطير ثنائي منفصل،
  /// وكافٍ لحجم الملفات المتوقَّع (رسائل صوتية قصيرة، صور، مستندات) على
  /// شبكة محلية سريعة. ليس الأنسب لملفات ضخمة جدًا، لكنه خارج نطاق النسخة
  /// الحالية.
  Map<String, dynamic> toWirePayload({String? base64Data}) {
    final payload = <String, dynamic>{
      'type': 'message',
      'id': id,
      'conversationId': conversationId,
      'senderInternalNumber': senderInternalNumber,
      'text': text,
      'sentAt': sentAt.toIso8601String(),
      'kind': kind.name,
    };
    if (attachmentFileName != null) payload['attachmentFileName'] = attachmentFileName;
    if (attachmentMimeType != null) payload['attachmentMimeType'] = attachmentMimeType;
    if (attachmentSizeBytes != null) payload['attachmentSizeBytes'] = attachmentSizeBytes;
    if (base64Data != null) payload['data'] = base64Data;
    return payload;
  }
}
