import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_event_test_');
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

/// يغطي هذا الملف الفعاليات في حالتين حقيقيتين عبر الشبكة: محادثة ثنائية
/// بين جهازين، ومحادثة جماعية بثلاثة أجهزة — يتأكد أن عنوان الفعالية
/// وموعدها ومكانها يصل، وأن الردود (RSVP) تُوزَّع فعليًا على كل من يشارك
/// في المحادثة، بنفس منطق [voteInPoll] المُختبَر في poll_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('إنشاء فعالية والرد عليها يصلان فعليًا للطرف الآخر في محادثة ثنائية', () async {
    const testPort = 46502;
    final deviceA = LocalConnectAppState(instanceId: 'event_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'event_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    await deviceB.init();
    await deviceA.init();

    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null);

    final conversationOnA =
        await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);

    final eventDateTime = DateTime(2027, 3, 15, 18, 30);
    await deviceA.sendEvent(
      conversationId: conversationOnA.id,
      title: 'اجتماع تنسيق',
      dateTime: eventDateTime,
      location: 'القاعة الرئيسية',
    );

    expect(
      await _waitUntil(() => deviceB.messagesFor(conversationOnA.id).any((m) => m.kind == MessageKind.event)),
      isTrue,
      reason: 'يجب أن تصل الفعالية لـB',
    );

    final eventOnB = deviceB.messagesFor(conversationOnA.id).firstWhere((m) => m.kind == MessageKind.event);
    expect(eventOnB.text, 'اجتماع تنسيق');
    expect(eventOnB.eventDateTime, eventDateTime);
    expect(eventOnB.eventLocation, 'القاعة الرئيسية');

    await deviceB.respondToEvent(
      conversationId: conversationOnA.id,
      messageId: eventOnB.id,
      status: EventRsvpStatus.going,
    );

    expect(
      await _waitUntil(() {
        final eventOnA =
            deviceA.messagesFor(conversationOnA.id).firstWhere((m) => m.kind == MessageKind.event);
        return eventOnA.eventRsvps?[deviceB.identity.internalNumber] == EventRsvpStatus.going.name;
      }),
      isTrue,
      reason: 'يجب أن يصل ردّ B فعليًا لـA',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('الردّ على فعالية داخل مجموعة يصل لكل الأعضاء الآخرين', () async {
    const testPort = 46503;
    final deviceA = LocalConnectAppState(instanceId: 'event_group_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'event_group_b', messagingPort: testPort);
    final deviceC = LocalConnectAppState(instanceId: 'event_group_c', messagingPort: testPort);
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
      name: 'مجموعة الفعالية',
      memberInternalNumbers: [deviceB.identity.internalNumber, deviceC.identity.internalNumber],
    );

    await _waitUntil(() => deviceB.conversations.any((c) => c.id == group.id && c.isGroup));
    await _waitUntil(() => deviceC.conversations.any((c) => c.id == group.id && c.isGroup));

    await deviceA.sendEvent(
      conversationId: group.id,
      title: 'حفل التخرج',
      dateTime: DateTime(2027, 6, 1, 10, 0),
    );

    expect(
      await _waitUntil(() => deviceB.messagesFor(group.id).any((m) => m.kind == MessageKind.event)),
      isTrue,
    );
    expect(
      await _waitUntil(() => deviceC.messagesFor(group.id).any((m) => m.kind == MessageKind.event)),
      isTrue,
    );

    final eventOnB = deviceB.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.event);
    await deviceB.respondToEvent(
      conversationId: group.id,
      messageId: eventOnB.id,
      status: EventRsvpStatus.maybe,
    );

    // A وC كلاهما (وليس فقط A كمُنشئ الفعالية) يجب أن يريا ردّ B — الردّ
    // يُوزَّع على كل أعضاء المجموعة مباشرة، وليس فقط لمنشئ الفعالية.
    expect(
      await _waitUntil(() {
        final eventOnA = deviceA.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.event);
        return eventOnA.eventRsvps?[deviceB.identity.internalNumber] == EventRsvpStatus.maybe.name;
      }),
      isTrue,
      reason: 'يجب أن يصل ردّ B لـA',
    );
    expect(
      await _waitUntil(() {
        final eventOnC = deviceC.messagesFor(group.id).firstWhere((m) => m.kind == MessageKind.event);
        return eventOnC.eventRsvps?[deviceB.identity.internalNumber] == EventRsvpStatus.maybe.name;
      }),
      isTrue,
      reason: 'يجب أن يصل ردّ B لـC أيضًا مباشرة، لا عبر A فقط',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
