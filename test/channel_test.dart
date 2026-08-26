import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_channel_test_');
    return dir.path;
  }
}

Future<bool> _waitUntil(bool Function() condition, {int timeoutSeconds = 10}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

/// قناة هي مجموعة (isGroup) بعلامة isChannel، تُعيد استخدام كل بروتوكول
/// المجموعات (الدعوة، العضوية، التوزيع) — يغطي هذا الاختبار ما يخصّها هي
/// تحديدًا: تصل الدعوة بعلامة isChannel صحيحة، ينشر المالك بنجاح، ومحاولة
/// متابع نشر رسالة تُرفَض محليًا ولا تصل لأحد حتى لو تجاوزها القيد محليًا.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('قناة: الدعوة تصل بعلامة القناة، ونشر المالك يصل، ومحاولة متابع تُرفَض', () async {
    const testPort = 46302;
    final owner = LocalConnectAppState(instanceId: 'channel_owner', messagingPort: testPort);
    final follower = LocalConnectAppState(instanceId: 'channel_follower', messagingPort: testPort);
    addTearDown(() {
      owner.dispose();
      follower.dispose();
    });

    await follower.init();
    await owner.init();

    await _waitUntil(() => owner.discovery.peerByInternalNumber(follower.identity.internalNumber) != null);
    await owner.addContactFromPeer(owner.discovery.peerByInternalNumber(follower.identity.internalNumber)!);

    final channel = await owner.createGroup(
      name: 'قناة الاختبار',
      memberInternalNumbers: [follower.identity.internalNumber],
      isChannel: true,
    );
    expect(channel.isChannel, isTrue);
    expect(channel.isGroup, isTrue);

    expect(
      await _waitUntil(() => follower.conversations.any((c) => c.id == channel.id)),
      isTrue,
      reason: 'يجب أن تصل دعوة القناة للمتابع',
    );
    final channelOnFollower = follower.conversations.firstWhere((c) => c.id == channel.id);
    expect(channelOnFollower.isChannel, isTrue, reason: 'علامة القناة يجب أن تصل ضمن الدعوة نفسها');

    // المالك ينشر — يجب أن يصل المتابع.
    await owner.sendMessage(conversationId: channel.id, text: 'إعلان رسمي');
    expect(
      await _waitUntil(() => follower.messagesFor(channel.id).any((m) => m.text == 'إعلان رسمي')),
      isTrue,
      reason: 'يجب أن يصل منشور المالك للمتابع',
    );

    // المتابع يحاول النشر — يُرفَض محليًا فلا يُرسَل شيء إطلاقًا.
    await follower.sendMessage(conversationId: channel.id, text: 'محاولة نشر من متابع');
    expect(
      follower.messagesFor(channel.id).where((m) => m.outgoing),
      isEmpty,
      reason: 'يجب ألا يُسجَّل أو يُرسَل أي شيء عند محاولة متابع النشر',
    );
    // انتظار قصير للتأكد من عدم وصول شيء لصاحب القناة أيضًا (لا يوجد ما
    // يمكن انتظاره بثقة هنا سوى غياب أي رسالة جديدة).
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(owner.messagesFor(channel.id).where((m) => !m.outgoing), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
