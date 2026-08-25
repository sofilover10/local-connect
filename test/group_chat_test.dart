import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_group_test_');
    return dir.path;
  }
}

/// ثلاثة أجهزة حقيقية على شبكة محلية فعلية (نفس المضيف هنا، منافذ مختلفة):
/// A ينشئ مجموعة تضم B وC، ويتحقق أن دعوة المجموعة تصل للاثنين فعليًا
/// (يبنيان نفس المحادثة محليًا)، وأن رسالة يرسلها B تصل لكل من A وC معًا
/// (توزيع نجمي من المُرسِل مباشرة لكل الأعضاء الآخرين).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('إنشاء مجموعة وتوزيع دعوتها ورسائلها على كل الأعضاء فعليًا عبر الشبكة', () async {
    const testPort = 45902;
    final deviceA = LocalConnectAppState(instanceId: 'group_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'group_b', messagingPort: testPort);
    final deviceC = LocalConnectAppState(instanceId: 'group_c', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
      deviceC.dispose();
    });

    await deviceB.init();
    await deviceC.init();
    await deviceA.init();

    Future<void> waitDiscovered(LocalConnectAppState device, String targetInternalNumber) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (device.discovery.peerByInternalNumber(targetInternalNumber) != null) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await waitDiscovered(deviceA, deviceB.identity.internalNumber);
    await waitDiscovered(deviceA, deviceC.identity.internalNumber);
    await waitDiscovered(deviceB, deviceA.identity.internalNumber);
    await waitDiscovered(deviceC, deviceA.identity.internalNumber);

    // A يضيف B وC كجهتَي اتصال أولًا — إنشاء مجموعة يتطلب جهات اتصال
    // محفوظة أصلًا (لا يوجد بحث عن أرقام عشوائية على الشبكة).
    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);
    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceC.identity.internalNumber)!);

    final groupOnA = await deviceA.createGroup(
      name: 'مجموعة الاختبار',
      memberInternalNumbers: [deviceB.identity.internalNumber, deviceC.identity.internalNumber],
    );

    Future<bool> waitForGroup(LocalConnectAppState device) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (device.conversations.any((c) => c.id == groupOnA.id && c.isGroup)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    }

    expect(await waitForGroup(deviceB), isTrue, reason: 'يجب أن تصل دعوة المجموعة لـB فعليًا وتُنشئ نفس المحادثة');
    expect(await waitForGroup(deviceC), isTrue, reason: 'يجب أن تصل دعوة المجموعة لـC فعليًا وتُنشئ نفس المحادثة');

    // B يرسل رسالة في المجموعة — يجب أن تصل لكل من A وC (توزيع نجمي من B
    // مباشرة، بلا مرور بـA كوسيط).
    await deviceB.sendMessage(conversationId: groupOnA.id, text: 'مرحبًا من B في المجموعة');

    Future<bool> waitForMessage(LocalConnectAppState device) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (device.messagesFor(groupOnA.id).any((m) => m.text == 'مرحبًا من B في المجموعة')) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    }

    expect(await waitForMessage(deviceA), isTrue, reason: 'يجب أن تصل رسالة B لـA عبر المجموعة');
    expect(await waitForMessage(deviceC), isTrue, reason: 'يجب أن تصل رسالة B لـC عبر المجموعة');

    // الرسالة الواردة لدى C يجب أن تحمل رقم B كمُرسِل فعلي، لا رقم A.
    final onC = deviceC.messagesFor(groupOnA.id).firstWhere((m) => m.text == 'مرحبًا من B في المجموعة');
    expect(onC.senderInternalNumber, deviceB.identity.internalNumber);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
