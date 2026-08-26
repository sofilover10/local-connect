part of 'app_state.dart';

/// حظر الأرقام الداخلية، وقيد النشر في القنوات (بث من طرف واحد).
extension BlockingExtension on LocalConnectAppState {
  bool isBlocked(String internalNumber) => blockedInternalNumbers.contains(internalNumber);

  bool _isConversationBlocked(String conversationId) {
    final matches = conversations.where((c) => c.id == conversationId);
    if (matches.isEmpty) return false;
    return blockedInternalNumbers.contains(matches.first.peerInternalNumber);
  }

  /// القنوات بث من طرف واحد فقط — المالك يملك حق النشر حصريًا؛ باقي
  /// الأنواع (محادثة ثنائية، مجموعة عادية) لا قيد عليها هنا.
  bool _canPostToConversation(String conversationId) {
    final matches = conversations.where((c) => c.id == conversationId);
    if (matches.isEmpty) return true;
    final conversation = matches.first;
    if (!conversation.isChannel) return true;
    return conversation.groupOwnerInternalNumber == identity.internalNumber;
  }

  Future<void> blockContact(String internalNumber) async {
    blockedInternalNumbers.add(internalNumber);
    await _store.blockedBox.put(internalNumber, DateTime.now().toIso8601String());
    _safeNotify();
  }

  Future<void> unblockContact(String internalNumber) async {
    blockedInternalNumbers.remove(internalNumber);
    await _store.blockedBox.delete(internalNumber);
    _safeNotify();
  }
}
