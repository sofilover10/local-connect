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
    this.isGroup = false,
    this.isChannel = false,
    List<String>? memberInternalNumbers,
    this.groupOwnerInternalNumber,
  }) : memberInternalNumbers = memberInternalNumbers ?? [];

  final String id;

  /// فارغ دائمًا للمجموعات — لا "طرف واحد" لمحادثة جماعية. استخدم
  /// [memberInternalNumbers] بدلًا منه فيها.
  final String peerInternalNumber;
  String peerDisplayName;
  String? lastMessagePreview;
  DateTime? lastMessageAt;

  /// الأرشفة محلية بحتة (كل جهاز يقرّرها بنفسه) — لا حاجة لإخبار الطرف
  /// الآخر أو أي مزامنة عبر الشبكة.
  bool isArchived;

  final bool isGroup;

  /// true لقناة بث (نشر من طرف واحد فقط) — نوع خاص من المجموعة (isGroup
  /// صحيح دائمًا لها أيضًا)؛ يُعيد استخدام كل بنية المجموعة (الدعوة،
  /// العضوية، التوزيع) بلا أي تغيير في البروتوكول، فقط يُقيَّد الإرسال على
  /// المالك عند التحقق في AppState.
  final bool isChannel;

  /// الأعضاء الآخرون في المجموعة (أو المتابعون في القناة) (**بدون** رقمي أنا) — يُستخدم مباشرة عند
  /// توزيع رسالة على الجميع. فارغة دائمًا لمحادثة ثنائية عادية.
  final List<String> memberInternalNumbers;

  /// منشئ المجموعة أصلًا (أو من أرسل الدعوة التي أنشأتها لديّ). لا صلاحيات
  /// إدارية خاصة مرتبطة به بعد في هذه النسخة — مجرّد معلومة عرض.
  final String? groupOwnerInternalNumber;

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
        'isGroup': isGroup,
        'isChannel': isChannel,
        'memberInternalNumbers': memberInternalNumbers,
        'groupOwnerInternalNumber': groupOwnerInternalNumber,
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
        isGroup: map['isGroup'] as bool? ?? false,
        isChannel: map['isChannel'] as bool? ?? false,
        memberInternalNumbers:
            (map['memberInternalNumbers'] as List<dynamic>?)?.cast<String>() ?? const [],
        groupOwnerInternalNumber: map['groupOwnerInternalNumber'] as String?,
      );
}
