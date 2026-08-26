import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_poll_test_');
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

/// يغطي هذا الملف استطلاعات الرأي في حالتين حقيقيتين عبر الشبكة: محادثة
/// ثنائية بين جهازين، ومحادثة جماعية بثلاثة أجهزة — يتأكد أن السؤال
/// والخيارات تصل، وأن التصويت يُوزَّع فعليًا (وليس محليًا فقط) على كل من
/// يشارك في المحادثة.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('إنشاء استطلاع والتصويت فيه يصلان فعليًا للطرف الآخر في محادثة ثنائية', () async {
    const testPort = 46102;
    final deviceA = LocalConnectAppState(instanceId: 'poll_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'poll_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    await deviceB.init();
    await deviceA.init();

    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null);

    final conversationOnA =
        await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);

    await deviceA.sendPoll(
      conversationId: conversationOnA.id,
      question: 'أي وقت يناسبكم؟',
      options: ['الصباح', 'المساء'],
    );

    expect(
      await _waitUntil(() => deviceB.messagesFor(conversationOnA.id).any((m) => m.kind == MessageKind.poll)),
      isTrue,
      reason: 'يجب أن يصل الاستطلاع لـB',
    );

    final pollOnB = deviceB.messagesFor(conversationOnA.id).firstWhere((m) => m.kind == MessageKind.poll);
    expect(pollOnB.pollOptions, ['الصباح', 'المساء']);

    // B يصوّت للخيار الثاني (فهرس 1).
    await deviceB.voteInPoll(conversationId: conversationOnA.id, messageId: pollOnB.id, optionIndex: 1);

    expect(
      await _waitUntil(() {
        final pollOnA =
            deviceA.messagesFor(conversationOnA.id).firstWhere((m) => m.kind == MessageKind.poll);
        return pollOnA.pollVotes?['1']?.contains(deviceB.identity.internalNumber) ?? false;
      }),
      isTrue,
      reason: 'يجب أن يصل تصويت B فعليًا لـA',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('التصويت في استطلاع داخل مجموعة يصل لكل الأعضاء الآخرين', () async {
    const testPort = 46103;
    final deviceA = LocalConnectAppState(instanceId: 'poll_group_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'poll_group_b', messagingPort: testPort);
    final deviceC = LocalConnectAppState(instanceId: 'poll_group_c', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
      deviceC.dispose();
    });

    await deviceB.init();
    await deviceC.init();
    await deviceA.init();

    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null);
    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceC.identity.internalNumber) != null);

    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);
    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceC.identity.internalNumber)!);

    final group = await deviceA.createGroup(
      name: 'مجموعة الاستطلاع',
      memberInternalNumbers: [deviceB.identity.internalNumber, deviceC.identity.internalNumber],
    );

    await _waitUntil(() => deviceB.conversations.any((c) => c.id == group.id && c.isGroup));
    await _waitUntil(() => deviceC.conversations.any((c) => c.id == group.id && c.isGroup));

    await deviceA.sendPoll(conversationId: group.id, question: 'مكان الاجتماع؟', options: ['المخيم', 'المدرسة']);

    expect(
      await _waitUntil(() => deviceB.messagesFor(group.id).any((m) => m.kind == MessageKind.poll)),
      isTrue,
    );
    expect(
      await _waitUntil(() => deviceC.messagesFor(group.id).any((m) => m.kind == MessageKind.poll)),
      isTrue,
    );

    final pollOnB = deviceB.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.poll);
    await deviceB.voteInPoll(conversationId: group.id, messageId: pollOnB.id, optionIndex: 0);

    // A وC كلاهما (وليس فقط A كمُرسِل الاستطلاع) يجب أن يريا تصويت B —
    // التصويت يُوزَّع على كل أعضاء المجموعة مباشرة، وليس فقط لمنشئ الاستطلاع.
    expect(
      await _waitUntil(() {
        final pollOnA = deviceA.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.poll);
        return pollOnA.pollVotes?['0']?.contains(deviceB.identity.internalNumber) ?? false;
      }),
      isTrue,
      reason: 'يجب أن يصل تصويت B لـA',
    );
    expect(
      await _waitUntil(() {
        final pollOnC = deviceC.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.poll);
        return pollOnC.pollVotes?['0']?.contains(deviceB.identity.internalNumber) ?? false;
      }),
      isTrue,
      reason: 'يجب أن يصل تصويت B لـC أيضًا مباشرة، لا عبر A فقط',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
