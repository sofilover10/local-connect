part of 'app_state.dart';

/// المجموعات (والقنوات، التي تُبنى فوق نفس بروتوكول المجموعات — انظر
/// [Conversation.isChannel]).
extension GroupsExtension on LocalConnectAppState {
  /// ينشئ مجموعة ويدعو أعضاءها الآخرين — كل واحد منهم يُنشئ لديه محليًا
  /// نفس المحادثة (بنفس [Conversation.id]) فور استلام دعوته، عبر
  /// [_handleGroupInvite]. لا خادم مركزي يُنسِّق العضوية؛ كل جهاز يوزّع
  /// رسائله على الأعضاء الآخرين مباشرة (انظر [_fanOutToGroup]).
  Future<Conversation> createGroup({
    required String name,
    required List<String> memberInternalNumbers,
    bool isChannel = false,
  }) async {
    final trimmedName = name.trim();
    final otherMembers = memberInternalNumbers.toSet().toList();
    final groupId = '${isChannel ? 'CH' : 'GRP'}-${const Uuid().v4().substring(0, 8).toUpperCase()}';

    final conversation = Conversation(
      id: groupId,
      peerInternalNumber: '',
      peerDisplayName: trimmedName,
      isGroup: true,
      isChannel: isChannel,
      memberInternalNumbers: otherMembers,
      groupOwnerInternalNumber: identity.internalNumber,
    );
    conversations.add(conversation);
    _messagesByConversation[groupId] = [];
    await _store.conversationsBox.put(groupId, _store.encode(conversation.toMap()));
    _safeNotify();

    final allMembersIncludingSelf = [identity.internalNumber, ...otherMembers];
    for (final member in otherMembers) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'group_invite',
        // معرّف لإقرار التسليم (ack) فقط — تُبنى دعوة جديدة بنفس المعرّف
        // لكل عضو تُرسَل له الآن، لا علاقة له بمعرّف الرسائل النصية.
        'id': const Uuid().v4(),
        'groupId': groupId,
        'groupName': trimmedName,
        'isChannel': isChannel,
        'members': allMembersIncludingSelf,
        'senderInternalNumber': identity.internalNumber,
      }));
    }

    return conversation;
  }

  /// يبدأ مكالمة جماعية (صوتية أو مرئية) لأعضاء محادثة جماعية قائمة —
  /// راجع [GroupCallService] لتفاصيل تنسيق الاتصال بين الأعضاء.
  Future<void> startGroupCall(Conversation group, {required CallMediaType mediaType}) async {
    if (!group.isGroup || group.memberInternalNumbers.isEmpty) return;
    final memberDisplayNames = <String, String>{};
    for (final internalNumber in group.memberInternalNumbers) {
      final matches = contacts.where((c) => c.internalNumber == internalNumber);
      memberDisplayNames[internalNumber] = matches.isEmpty ? internalNumber : matches.first.displayName;
    }
    await groupCallService.startGroupCall(
      groupId: group.id,
      groupName: group.peerDisplayName,
      memberDisplayNames: memberDisplayNames,
      mediaType: mediaType,
    );
  }

  /// يبني نفس المحادثة الجماعية محليًا لدى عضو مدعوّ حديثًا — أو يُحدِّث
  /// قائمة الأعضاء إن وصلت دعوة لمجموعة موجودة أصلًا لديه (مثلًا انضم عضو
  /// جديد لاحقًا وأعاد المنشئ إرسال الدعوة للجميع).
  void _handleGroupInvite(String senderInternalNumber, Map<String, dynamic> payload) {
    final groupId = payload['groupId'];
    final groupName = payload['groupName'];
    final membersRaw = payload['members'];
    if (groupId is! String ||
        !_isSafeIdentifier(groupId) ||
        groupName is! String ||
        groupName.trim().isEmpty ||
        membersRaw is! List) {
      recordError('دعوة مجموعة', 'حمولة غير صالحة من الشبكة تم تجاهلها');
      return;
    }

    final members = membersRaw.whereType<String>().where(_isSafeIdentifier).toSet().toList();
    // دعوة لا تشملني أصلًا لا معنى لقبولها — إما خطأ أو محاولة تلاعب.
    if (!members.contains(identity.internalNumber)) {
      recordError('دعوة مجموعة', 'دعوة مجموعة لا تشملني تم تجاهلها');
      return;
    }
    final otherMembers = members.where((m) => m != identity.internalNumber).toList();
    final isChannel = payload['isChannel'] == true;

    final existingIndex = conversations.indexWhere((c) => c.id == groupId);
    if (existingIndex == -1) {
      final conversation = Conversation(
        id: groupId,
        peerInternalNumber: '',
        peerDisplayName: groupName,
        isGroup: true,
        isChannel: isChannel,
        memberInternalNumbers: otherMembers,
        groupOwnerInternalNumber: senderInternalNumber,
      );
      conversations.add(conversation);
      _messagesByConversation[groupId] = [];
      unawaited(_store.conversationsBox.put(groupId, _store.encode(conversation.toMap())));
    } else {
      final conversation = conversations[existingIndex];
      conversation.memberInternalNumbers
        ..clear()
        ..addAll(otherMembers);
      unawaited(_store.conversationsBox.put(groupId, _store.encode(conversation.toMap())));
    }
    _safeNotify();
  }

  /// يضيف عضوًا جديدًا لمجموعة قائمة — يقتصر على مالك المجموعة (منشئها)
  /// في هذه النسخة، لعدم وجود صلاحيات إدارية متدرّجة بعد. يُرسِل دعوة كاملة
  /// للعضو الجديد، ويُبلِغ بقية الأعضاء بالقائمة المُحدَّثة.
  Future<void> addGroupMember(String groupId, String newMemberInternalNumber) async {
    final index = conversations.indexWhere((c) => c.id == groupId && c.isGroup);
    if (index == -1) return;
    final group = conversations[index];
    if (group.groupOwnerInternalNumber != identity.internalNumber) return;
    if (group.memberInternalNumbers.contains(newMemberInternalNumber)) return;

    group.memberInternalNumbers.add(newMemberInternalNumber);
    await _store.conversationsBox.put(groupId, _store.encode(group.toMap()));
    _safeNotify();

    final allMembers = [identity.internalNumber, ...group.memberInternalNumbers];
    unawaited(_deliverViaAnyTransport(newMemberInternalNumber, {
      'type': 'group_invite',
      'id': const Uuid().v4(),
      'groupId': groupId,
      'groupName': group.peerDisplayName,
      'members': allMembers,
      'senderInternalNumber': identity.internalNumber,
    }));
    for (final member in group.memberInternalNumbers.where((m) => m != newMemberInternalNumber)) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'group_member_update',
        'id': const Uuid().v4(),
        'groupId': groupId,
        'members': allMembers,
        'senderInternalNumber': identity.internalNumber,
      }));
    }
  }

  /// يزيل عضوًا من مجموعة — للمالك فقط أيضًا. يُبلَّغ العضو المُزال بقائمة
  /// أعضاء لا تتضمنه، فيحذف المحادثة محليًا لديه تلقائيًا (نفس آلية
  /// [_handleGroupMemberUpdate] التي تتعامل مع المغادرة الطوعية أيضًا).
  Future<void> removeGroupMember(String groupId, String memberInternalNumber) async {
    final index = conversations.indexWhere((c) => c.id == groupId && c.isGroup);
    if (index == -1) return;
    final group = conversations[index];
    if (group.groupOwnerInternalNumber != identity.internalNumber) return;
    if (!group.memberInternalNumbers.remove(memberInternalNumber)) return;
    await _store.conversationsBox.put(groupId, _store.encode(group.toMap()));
    _safeNotify();

    final remainingMembers = [identity.internalNumber, ...group.memberInternalNumbers];
    for (final member in [...group.memberInternalNumbers, memberInternalNumber]) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'group_member_update',
        'id': const Uuid().v4(),
        'groupId': groupId,
        'members': remainingMembers,
        'senderInternalNumber': identity.internalNumber,
      }));
    }
  }

  /// يغادر عضو (أي عضو، بما فيه المالك) مجموعة بنفسه. لا يوجد نقل ملكية
  /// تلقائي إن غادر المالك — تبقى المجموعة بلا مالك لدى البقية، فتُعطَّل
  /// إضافة/إزالة الأعضاء فيها إلى أن تُبنى هذه الميزة لاحقًا.
  Future<void> leaveGroup(String groupId) async {
    final index = conversations.indexWhere((c) => c.id == groupId && c.isGroup);
    if (index == -1) return;
    final group = conversations[index];
    final remainingMembers = List<String>.from(group.memberInternalNumbers);

    conversations.removeAt(index);
    _messagesByConversation.remove(groupId);
    await _store.conversationsBox.delete(groupId);
    _safeNotify();

    for (final member in remainingMembers) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'group_member_update',
        'id': const Uuid().v4(),
        'groupId': groupId,
        'members': remainingMembers,
        'senderInternalNumber': identity.internalNumber,
      }));
    }
  }

  /// يُحدِّث قائمة أعضاء مجموعة قائمة أصلًا لدينا (إضافة/إزالة/مغادرة عضو)،
  /// أو يحذفها محليًا إن لم يعد رقمي ضمن القائمة الجديدة (تمت إزالتي، أو
  /// غادرتُ من جهاز آخر يشارك نفس الهوية).
  void _handleGroupMemberUpdate(Map<String, dynamic> payload) {
    final groupId = payload['groupId'];
    final membersRaw = payload['members'];
    if (groupId is! String || !_isSafeIdentifier(groupId) || membersRaw is! List) return;

    final index = conversations.indexWhere((c) => c.id == groupId && c.isGroup);
    if (index == -1) return; // لسنا عضوًا في هذه المجموعة أصلًا لدينا

    final members = membersRaw.whereType<String>().where(_isSafeIdentifier).toSet().toList();
    if (!members.contains(identity.internalNumber)) {
      conversations.removeAt(index);
      _messagesByConversation.remove(groupId);
      unawaited(_store.conversationsBox.delete(groupId));
      _safeNotify();
      return;
    }

    final conversation = conversations[index];
    final otherMembers = members.where((m) => m != identity.internalNumber).toList();
    conversation.memberInternalNumbers
      ..clear()
      ..addAll(otherMembers);
    unawaited(_store.conversationsBox.put(groupId, _store.encode(conversation.toMap())));
    _safeNotify();
  }
}
