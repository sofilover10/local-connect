enum MessageStatus { queued, sent, delivered, failed }

enum MessageKind { text, file, voice, poll }

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
    this.editedAt,
    this.isDeleted = false,
    this.pollOptions,
    Map<String, List<String>>? pollVotes,
  }) : pollVotes = pollVotes ??
            (pollOptions == null
                ? null
                : {for (var i = 0; i < pollOptions.length; i++) '$i': <String>[]});

  final String id;
  final String conversationId;
  final String senderInternalNumber;

  /// النص إن كانت رسالة نصية، أو تعليق/اسم قصير إن كانت مرفقًا. قابل
  /// للتعديل لدعم تحرير الرسائل النصية الصادرة بعد إرسالها.
  String text;
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

  /// وقت آخر تعديل على نص الرسالة، أو null إن لم تُعدَّل قط.
  DateTime? editedAt;

  /// حذف "للجميع" — تبقى الرسالة في مكانها بالمحادثة كعنصر نائب فارغ بدل
  /// حذفها من القائمة، بنفس أسلوب واتساب. حذف "لي فقط" يُزيل السجل محليًا
  /// بالكامل بدل استخدام هذا العلم.
  bool isDeleted;

  /// خيارات الاستطلاع — [text] يحمل نص السؤال لرسائل النوع poll. فارغة
  /// لأي نوع رسالة آخر.
  final List<String>? pollOptions;

  /// تصويتات الاستطلاع: مفتاح الخريطة هو رقم الخيار كنص (فهرسه في
  /// [pollOptions])، والقيمة قائمة الأرقام الداخلية لمن صوّتوا له. صوت
  /// واحد فقط لكل شخص (يُنقَل تلقائيًا عند تغيير اختياره)؛ راجع
  /// AppState.voteInPoll.
  Map<String, List<String>>? pollVotes;

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
        'editedAt': editedAt?.toIso8601String(),
        'isDeleted': isDeleted,
        'pollOptions': pollOptions,
        'pollVotes': pollVotes,
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
        editedAt: map['editedAt'] == null ? null : DateTime.parse(map['editedAt'] as String),
        isDeleted: map['isDeleted'] as bool? ?? false,
        pollOptions: (map['pollOptions'] as List<dynamic>?)?.cast<String>(),
        pollVotes: (map['pollVotes'] as Map<String, dynamic>?)
            ?.map((key, value) => MapEntry(key, (value as List<dynamic>).cast<String>())),
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
    if (pollOptions != null) payload['pollOptions'] = pollOptions;
    if (pollVotes != null) payload['pollVotes'] = pollVotes;
    return payload;
  }
}
