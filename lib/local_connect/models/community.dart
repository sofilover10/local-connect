/// مجتمع: حاوية تُجمِّع عدة مجموعات/قنوات موجودة أصلًا تحت اسم واحد —
/// عضويته منفصلة عن عضوية كل مجموعة منضوية فيه (الانضمام للمجتمع لا يضمّك
/// تلقائيًا لأي مجموعة داخله في هذه النسخة؛ يبقى ذلك بيد مالك كل مجموعة
/// على حدة). يُعاد استخدام نفس أسلوب الدعوة/التوزيع المستخدَم للمجموعات.
class Community {
  Community({
    required this.id,
    required this.name,
    required this.ownerInternalNumber,
    List<String>? memberInternalNumbers,
    List<String>? linkedConversationIds,
  })  : memberInternalNumbers = memberInternalNumbers ?? [],
        linkedConversationIds = linkedConversationIds ?? [];

  final String id;
  String name;
  final String ownerInternalNumber;

  /// أعضاء المجتمع الآخرون (بدون رقمي أنا).
  final List<String> memberInternalNumbers;

  /// معرّفات محادثات (مجموعات أو قنوات) مُدرَجة ضمن هذا المجتمع — عرضية
  /// فقط هنا؛ فتح إحداها يتطلب أن تكون عضوًا فيها أصلًا كأي مجموعة عادية.
  final List<String> linkedConversationIds;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'ownerInternalNumber': ownerInternalNumber,
        'memberInternalNumbers': memberInternalNumbers,
        'linkedConversationIds': linkedConversationIds,
      };

  factory Community.fromMap(Map<String, dynamic> map) => Community(
        id: map['id'] as String,
        name: map['name'] as String,
        ownerInternalNumber: map['ownerInternalNumber'] as String,
        memberInternalNumbers: (map['memberInternalNumbers'] as List<dynamic>?)?.cast<String>(),
        linkedConversationIds: (map['linkedConversationIds'] as List<dynamic>?)?.cast<String>(),
      );
}
