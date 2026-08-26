import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_group_membership_test_');
    return dir.path;
  }
}

/// ثلاثة أجهزة حقيقية: A (المالك) ينشئ مجموعة تضم B فقط، ثم يضيف C لاحقًا
/// (يجب أن تصل C دعوة كاملة، وأن يعرف B بانضمام C)، ثم يزيل B (يجب أن
/// تختفي المجموعة لدى B محليًا، وأن يعرف C أن B لم يعد عضوًا)، ثم C يغادر
/// بنفسه (يجب أن تختفي المجموعة لدى C، وأن يرى A أن لا أعضاء تبقّوا).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('إضافة وإزالة ومغادرة أعضاء مجموعة تنعكس فعليًا على كل الأجهزة عبر الشبكة', () async {
    const testPort = 46002;
    final deviceA = LocalConnectAppState(instanceId: 'gm_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'gm_b', messagingPort: testPort);
    final deviceC = LocalConnectAppState(instanceId: 'gm_c', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
      deviceC.dispose();
    });

    await deviceB.init();
    await deviceC.init();
    await deviceA.init();

    Future<void> waitDiscovered(LocalConnectAppState device, String target) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (device.discovery.peerByInternalNumber(target) != null) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await waitDiscovered(deviceA, deviceB.identity.internalNumber);
    await waitDiscovered(deviceA, deviceC.identity.internalNumber);

    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);
    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceC.identity.internalNumber)!);

    final group = await deviceA.createGroup(
      name: 'مجموعة العضوية',
      memberInternalNumbers: [deviceB.identity.internalNumber],
    );

    Future<bool> waitUntil(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (condition()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    }

    expect(
      await waitUntil(() => deviceB.conversations.any((c) => c.id == group.id && c.isGroup)),
      isTrue,
      reason: 'B يجب أن يستلم الدعوة الأولى',
    );

    // A يضيف C لاحقًا.
    await deviceA.addGroupMember(group.id, deviceC.identity.internalNumber);

    expect(
      await waitUntil(() => deviceC.conversations.any((c) => c.id == group.id && c.isGroup)),
      isTrue,
      reason: 'C يجب أن يستلم دعوة الانضمام المتأخرة',
    );
    expect(
      await waitUntil(() {
        final onB = deviceB.conversations.where((c) => c.id == group.id);
        return onB.isNotEmpty && onB.first.memberInternalNumbers.contains(deviceC.identity.internalNumber);
      }),
      isTrue,
      reason: 'B يجب أن يعرف أن C انضم للمجموعة',
    );

    // A يزيل B.
    await deviceA.removeGroupMember(group.id, deviceB.identity.internalNumber);

    expect(
      await waitUntil(() => !deviceB.conversations.any((c) => c.id == group.id)),
      isTrue,
      reason: 'B يجب أن تختفي لديه المجموعة بعد إزالته',
    );
    expect(
      await waitUntil(() {
        final onC = deviceC.conversations.where((c) => c.id == group.id);
        return onC.isNotEmpty && !onC.first.memberInternalNumbers.contains(deviceB.identity.internalNumber);
      }),
      isTrue,
      reason: 'C يجب أن يعرف أن B لم يعد عضوًا',
    );

    // C يغادر بنفسه.
    await deviceC.leaveGroup(group.id);
    expect(deviceC.conversations.any((c) => c.id == group.id), isFalse);

    expect(
      await waitUntil(() {
        final onA = deviceA.conversations.where((c) => c.id == group.id);
        return onA.isNotEmpty && onA.first.memberInternalNumbers.isEmpty;
      }),
      isTrue,
      reason: 'A يجب أن يرى أن لا أعضاء آخرين تبقّوا بعد مغادرة C',
    );
  }, timeout: const Timeout(Duration(seconds: 45)));
}
