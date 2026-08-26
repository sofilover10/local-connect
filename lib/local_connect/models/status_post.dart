enum StatusKind { text, image, file }

/// حالة (منشور مؤقت) يظهر لجهات الاتصال لمدة 24 ساعة ثم يختفي تلقائيًا —
/// لا خادم مركزي، فيُبَثّ المنشور عند نشره لكل جهة اتصال مباشرة (انظر
/// AppState.postStatus)، ويحمل كل جهاز نسخته الخاصة محليًا.
class StatusPost {
  StatusPost({
    required this.id,
    required this.authorInternalNumber,
    required this.authorDisplayName,
    required this.postedAt,
    this.text,
    this.kind = StatusKind.text,
    this.attachmentFileName,
    this.attachmentMimeType,
    this.attachmentLocalPath,
    List<String>? viewedBy,
  }) : viewedBy = viewedBy ?? [];

  final String id;
  final String authorInternalNumber;
  final String authorDisplayName;
  final DateTime postedAt;
  final String? text;
  final StatusKind kind;
  final String? attachmentFileName;
  final String? attachmentMimeType;
  String? attachmentLocalPath;

  /// الأرقام الداخلية لمن شاهدوا هذه الحالة — مُرسِلة فقط ذات معنى (ترد
  /// إشعارات مشاهدة إليه من الآخرين)؛ نسخة الحالة لدى المُشاهدين أنفسهم لا
  /// تتضمن هذه القائمة أصلًا.
  final List<String> viewedBy;

  static const Duration lifetime = Duration(hours: 24);

  bool get isExpired => DateTime.now().difference(postedAt) > lifetime;

  Map<String, dynamic> toMap() => {
        'id': id,
        'authorInternalNumber': authorInternalNumber,
        'authorDisplayName': authorDisplayName,
        'postedAt': postedAt.toIso8601String(),
        'text': text,
        'kind': kind.name,
        'attachmentFileName': attachmentFileName,
        'attachmentMimeType': attachmentMimeType,
        'attachmentLocalPath': attachmentLocalPath,
        'viewedBy': viewedBy,
      };

  factory StatusPost.fromMap(Map<String, dynamic> map) => StatusPost(
        id: map['id'] as String,
        authorInternalNumber: map['authorInternalNumber'] as String,
        authorDisplayName: map['authorDisplayName'] as String,
        postedAt: DateTime.parse(map['postedAt'] as String),
        text: map['text'] as String?,
        kind: StatusKind.values.byName(map['kind'] as String? ?? 'text'),
        attachmentFileName: map['attachmentFileName'] as String?,
        attachmentMimeType: map['attachmentMimeType'] as String?,
        attachmentLocalPath: map['attachmentLocalPath'] as String?,
        viewedBy: (map['viewedBy'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
}
