import 'call_session.dart' show CallMediaType;

enum GroupCallState { ringing, active, ended }

/// حالة اتصال WebRTC الفعلي مع مشارك مُحدَّد داخل مكالمة جماعية — كل زوج
/// من المشاركين يحتاج اتصال WebRTC مباشر خاص به (لا يوجد خادم وسائط
/// (SFU) يُوزِّع الصوت، فكل جهاز يرسل صوته مباشرة لكل مشارك آخر).
enum ParticipantLinkState { connecting, connected, failed }

class GroupCallParticipant {
  GroupCallParticipant({required this.internalNumber, required this.displayName});

  final String internalNumber;
  final String displayName;
  ParticipantLinkState linkState = ParticipantLinkState.connecting;
  bool isMuted = false;

  /// true إن كان هذا المشارك قد أرسل فعليًا group_call_join (أو كان
  /// المُنسِّق نفسه) — بخلاف كونه مجرّد مدعوّ لم يردّ بعد. يُستخدَم لتمييز
  /// "دُعي" عن "نشِط الآن فعليًا" أثناء بناء قوائم المشاركين المُوزَّعة.
  bool hasJoined = false;
}

/// مكالمة صوتية جماعية واحدة جارية أو منتهية للتوّ. المُنسِّق (المُتصل الذي
/// بدأ المكالمة) يتتبّع من قَبِل الدعوة فعليًا (participants)، ويُبلِغ كل
/// مشارك نشِط بأي مشارك جديد ينضم — انظر GroupCallService لتفاصيل هذا
/// التنسيق. ليس خادم وسائط؛ فقط يتتبّع من هو "نشِط الآن" حتى يعرف كل طرف
/// من يجب أن يتصل به مباشرة.
class GroupCallSession {
  GroupCallSession({
    required this.callId,
    required this.groupId,
    required this.groupName,
    required this.isInitiator,
    required this.mediaType,
  }) : startedAt = DateTime.now();

  final String callId;
  final String groupId;
  final String groupName;
  final CallMediaType mediaType;

  /// true إن كان هذا الجهاز هو من بدأ المكالمة — هو المُنسِّق الذي يتتبّع
  /// قائمة "النشِطين الآن" ويُبلِغ الجميع بالتحديثات (انظر التوثيق أعلاه).
  final bool isInitiator;

  final DateTime startedAt;
  GroupCallState state = GroupCallState.ringing;

  /// كل من نعرف عنه في هذه المكالمة (بدون نفسي): لدى المُنسِّق هم كل من
  /// دُعي (سواء انضمّ أم لا يزال ينتظر رده)، ولدى غيره هم فقط من عرفهم عبر
  /// دعوته أو قائمة نشِطين مُوزَّعة (group_call_roster) أو عرضًا (offer)
  /// وصله مباشرة.
  final Map<String, GroupCallParticipant> participants = {};

  Duration get elapsed => DateTime.now().difference(startedAt);
}
