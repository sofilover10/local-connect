import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_blocking_test_');
    return dir.path;
  }
}

/// جهازان حقيقيان على شبكة محلية فعلية (نفس المضيف هنا، منافذ مختلفة) —
/// يتأكد أن حظر رقم داخلي يمنع وصول رسائله فعليًا عبر الشبكة، وليس فقط
/// إخفاءها في الواجهة، وأن الطرف الحاظر لا يستطيع هو نفسه إرسال رسالة
/// لطرف حظره.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('حظر رقم داخلي يمنع وصول رسائله فعليًا ويمنع إرسال رسالة له', () async {
    const testPort = 45802;
    final deviceA = LocalConnectAppState(instanceId: 'blocking_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'blocking_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    await deviceB.init();
    await deviceA.init();

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) &&
        (deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) == null ||
            deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber) == null)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    final conversationOnA = await deviceA.addContactFromPeer(
      deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!,
    );
    await deviceB.addContactFromPeer(
      deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber)!,
    );

    await deviceA.blockContact(deviceB.identity.internalNumber);
    expect(deviceA.isBlocked(deviceB.identity.internalNumber), isTrue);

    // B يرسل قبل أن يعرف أنه محظور فعليًا (لا يوجد إخطار للطرف المحظور) —
    // A يجب ألا يستقبلها إطلاقًا.
    await deviceB.sendMessage(conversationId: conversationOnA.id, text: 'رسالة من طرف محظور');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      deviceA.messagesFor(conversationOnA.id).where((m) => !m.outgoing),
      isEmpty,
      reason: 'يجب ألا تصل أي رسالة واردة من رقم محظور',
    );

    // A نفسه لا يستطيع إرسال رسالة لطرف حظره، حتى لو حاول.
    await deviceA.sendMessage(conversationId: conversationOnA.id, text: 'محاولة إرسال لمحظور');
    expect(
      deviceA.messagesFor(conversationOnA.id).where((m) => m.outgoing),
      isEmpty,
      reason: 'يجب ألا تُسجَّل أو تُرسَل رسالة صادرة لطرف محظور',
    );

    await deviceA.unblockContact(deviceB.identity.internalNumber);
    expect(deviceA.isBlocked(deviceB.identity.internalNumber), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
