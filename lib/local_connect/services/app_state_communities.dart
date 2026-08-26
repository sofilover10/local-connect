part of 'app_state.dart';

/// المجتمعات (حاويات تُجمِّع مجموعات/قنوات موجودة أصلًا) — انظر توثيق
/// [Community] لتفاصيل التصميم المُبسَّط في هذه النسخة.
extension CommunitiesExtension on LocalConnectAppState {
  Future<void> _loadCommunities() async {
    communities
      ..clear()
      ..addAll(_store.communityBox.values.map((raw) => Community.fromMap(_store.decode(raw))));
  }

  /// [linkedConversationIds] يجب أن تكون مجموعات/قنوات أملكها أنا فعلًا
  /// (تحقّق الواجهة من ذلك)؛ الانضمام للمجتمع **لا** يضمّ العضو تلقائيًا
  /// لأي منها في هذه النسخة — مجرّد دليل يجمعها تحت اسم واحد.
  Future<Community> createCommunity({
    required String name,
    required List<String> memberInternalNumbers,
    List<String> linkedConversationIds = const [],
  }) async {
    final trimmedName = name.trim();
    final otherMembers = memberInternalNumbers.toSet().toList();
    final communityId = 'COM-${const Uuid().v4().substring(0, 8).toUpperCase()}';

    final community = Community(
      id: communityId,
      name: trimmedName,
      ownerInternalNumber: identity.internalNumber,
      memberInternalNumbers: otherMembers,
      linkedConversationIds: linkedConversationIds,
    );
    communities.add(community);
    await _store.communityBox.put(communityId, _store.encode(community.toMap()));
    _safeNotify();

    final allMembersIncludingSelf = [identity.internalNumber, ...otherMembers];
    for (final member in otherMembers) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'community_invite',
        'id': const Uuid().v4(),
        'communityId': communityId,
        'communityName': trimmedName,
        'members': allMembersIncludingSelf,
        'linkedConversationIds': linkedConversationIds,
        'senderInternalNumber': identity.internalNumber,
      }));
    }

    return community;
  }

  void _handleIncomingCommunityInvite(String senderInternalNumber, Map<String, dynamic> payload) {
    final communityId = payload['communityId'];
    final communityName = payload['communityName'];
    final membersRaw = payload['members'];
    if (communityId is! String ||
        !_isSafeIdentifier(communityId) ||
        communityName is! String ||
        communityName.trim().isEmpty ||
        membersRaw is! List) {
      recordError('دعوة مجتمع', 'حمولة غير صالحة من الشبكة تم تجاهلها');
      return;
    }

    final members = membersRaw.whereType<String>().where(_isSafeIdentifier).toSet().toList();
    if (!members.contains(identity.internalNumber)) {
      recordError('دعوة مجتمع', 'دعوة مجتمع لا تشملني تم تجاهلها');
      return;
    }
    final otherMembers = members.where((m) => m != identity.internalNumber).toList();
    final linkedConversationIds =
        (payload['linkedConversationIds'] as List<dynamic>?)?.whereType<String>().toList() ?? const [];

    final existingIndex = communities.indexWhere((c) => c.id == communityId);
    final community = Community(
      id: communityId,
      name: communityName,
      ownerInternalNumber: senderInternalNumber,
      memberInternalNumbers: otherMembers,
      linkedConversationIds: linkedConversationIds,
    );
    if (existingIndex == -1) {
      communities.add(community);
    } else {
      communities[existingIndex] = community;
    }
    unawaited(_store.communityBox.put(communityId, _store.encode(community.toMap())));
    _safeNotify();
  }

  /// يغادر عضو مجتمعًا بنفسه (لا صلاحيات إدارية متدرّجة بعد — أي عضو،
  /// بما فيه المالك، يقدر يغادر). لا يؤثر هذا على عضويته في أي مجموعة
  /// منضوية داخل المجتمع؛ تلك مستقلة تمامًا.
  Future<void> leaveCommunity(String communityId) async {
    final index = communities.indexWhere((c) => c.id == communityId);
    if (index == -1) return;
    final community = communities[index];
    final remainingMembers = List<String>.from(community.memberInternalNumbers);

    communities.removeAt(index);
    await _store.communityBox.delete(communityId);
    _safeNotify();

    for (final member in remainingMembers) {
      unawaited(_deliverViaAnyTransport(member, {
        'type': 'community_member_update',
        'id': const Uuid().v4(),
        'communityId': communityId,
        'members': remainingMembers,
        'senderInternalNumber': identity.internalNumber,
      }));
    }
  }

  void _handleIncomingCommunityMemberUpdate(Map<String, dynamic> payload) {
    final communityId = payload['communityId'];
    final membersRaw = payload['members'];
    if (communityId is! String || !_isSafeIdentifier(communityId) || membersRaw is! List) return;

    final index = communities.indexWhere((c) => c.id == communityId);
    if (index == -1) return;

    final members = membersRaw.whereType<String>().where(_isSafeIdentifier).toSet().toList();
    if (!members.contains(identity.internalNumber)) {
      communities.removeAt(index);
      unawaited(_store.communityBox.delete(communityId));
      _safeNotify();
      return;
    }

    final community = communities[index];
    final otherMembers = members.where((m) => m != identity.internalNumber).toList();
    community.memberInternalNumbers
      ..clear()
      ..addAll(otherMembers);
    unawaited(_store.communityBox.put(communityId, _store.encode(community.toMap())));
    _safeNotify();
  }
}
