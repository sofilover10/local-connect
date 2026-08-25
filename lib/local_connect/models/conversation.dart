/// محادثة ثنائية بين هذا الجهاز وجهة اتصال أخرى، مُعرَّفة برقمها الداخلي.
///
/// المعرّف [id] يُحسب من دمج الرقمين الداخليين مرتبين أبجديًا، بحيث يصل
/// الطرفان لنفس المعرّف دون الحاجة لتنسيق مسبق عبر خادم مركزي.
class Conversation {
  Conversation({
    required this.id,
    required this.peerInternalNumber,
    required this.peerDisplayName,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.isArchived = false,
  });

  final String id;
  final String peerInternalNumber;
  String peerDisplayName;
  String? lastMessagePreview;
  DateTime? lastMessageAt;

  /// الأرشفة محلية بحتة (كل جهاز يقرّرها بنفسه) — لا حاجة لإخبار الطرف
  /// الآخر أو أي مزامنة عبر الشبكة.
  bool isArchived;

  static String idFor(String internalNumberA, String internalNumberB) {
    final pair = [internalNumberA, internalNumberB]..sort();
    return '${pair[0]}_${pair[1]}';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'peerInternalNumber': peerInternalNumber,
        'peerDisplayName': peerDisplayName,
        'lastMessagePreview': lastMessagePreview,
        'lastMessageAt': lastMessageAt?.toIso8601String(),
        'isArchived': isArchived,
      };

  factory Conversation.fromMap(Map<String, dynamic> map) => Conversation(
        id: map['id'] as String,
        peerInternalNumber: map['peerInternalNumber'] as String,
        peerDisplayName: map['peerDisplayName'] as String,
        lastMessagePreview: map['lastMessagePreview'] as String?,
        lastMessageAt: map['lastMessageAt'] == null
            ? null
            : DateTime.parse(map['lastMessageAt'] as String),
        isArchived: map['isArchived'] as bool? ?? false,
      );
}
