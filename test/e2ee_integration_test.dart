import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_test_');
    return dir.path;
  }
}

/// يتأكد أن التشفير من طرف لطرف يعمل فعليًا عبر الشبكة الحقيقية (وليس فقط
/// على مستوى E2eeService المعزول): أول رسالة بين جهازين تصل بلا تشفير
/// (لا يُعرَف مفتاح الطرف الآخر بعد)، وكل رسالة بعدها في الاتجاهين تُشفَّر
/// تلقائيًا — راجع توثيق E2eeService لتفاصيل هذا التصميم.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('الرسالة الأولى بلا تشفير (تبادل مفاتيح)، وما بعدها مشفَّر فعليًا في الاتجاهين', () async {
    final deviceA = LocalConnectAppState(instanceId: 'e2ee_int_a');
    final deviceB = LocalConnectAppState(instanceId: 'e2ee_int_b');

    await deviceA.init();
    await deviceB.init();
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final aSeesB = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null;
      final bSeesA = deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber) != null;
      if (aSeesB && bSeesA) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final conversationOnA = await deviceA.addContactFromPeer(
      deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!,
    );

    // لا يعرف أي طرف مفتاح الآخر بعد قبل أي تواصل.
    expect(deviceA.e2ee.hasKeyFor(deviceB.identity.internalNumber), isFalse);
    expect(deviceB.e2ee.hasKeyFor(deviceA.identity.internalNumber), isFalse);

    await deviceA.sendMessage(conversationId: conversationOnA.id, text: 'أول رسالة — لا تشفير بعد');

    List<ChatMessage> receivedOnB = [];
    final firstDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(firstDeadline)) {
      final conversationId = deviceB.conversations
          .where((c) => c.peerInternalNumber == deviceA.identity.internalNumber)
          .map((c) => c.id);
      if (conversationId.isNotEmpty) {
        receivedOnB = deviceB.messagesFor(conversationId.first);
        if (receivedOnB.isNotEmpty) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    expect(receivedOnB, hasLength(1));
    expect(receivedOnB.first.text, 'أول رسالة — لا تشفير بعد');

    // بعد استلام الرسالة الأولى، صار B يعرف مفتاح A (وصل ضمن حمولتها).
    expect(deviceB.e2ee.hasKeyFor(deviceA.identity.internalNumber), isTrue);

    final conversationOnB = deviceB.conversations
        .firstWhere((c) => c.peerInternalNumber == deviceA.identity.internalNumber);
    await deviceB.sendMessage(conversationId: conversationOnB.id, text: 'رد مشفَّر فعليًا الآن');

    List<ChatMessage> receivedOnA = [];
    final secondDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(secondDeadline)) {
      receivedOnA = deviceA.messagesFor(conversationOnA.id).where((m) => !m.outgoing).toList();
      if (receivedOnA.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    expect(
      receivedOnA,
      hasLength(1),
      reason: 'يُفترض أن يصل الرد المشفَّر لجهاز A ويُفكَّ تشفيره بنجاح',
    );
    expect(receivedOnA.first.text, 'رد مشفَّر فعليًا الآن');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
