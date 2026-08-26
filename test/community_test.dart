import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_community_test_');
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

/// يتحقق أن دعوة المجتمع تصل فعليًا عبر الشبكة مع معرّفات المجموعات
/// المُدرَجة فيه، وأن المغادرة تُبلَّغ للأعضاء المتبقين — بنفس أسلوب اختبار
/// عضوية المجموعات.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('مجتمع: الدعوة تصل بمعرّفات المجموعات المُدرَجة، والمغادرة تصل للمتبقين', () async {
    const testPort = 46402;
    final deviceA = LocalConnectAppState(instanceId: 'community_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'community_b', messagingPort: testPort);
    final deviceC = LocalConnectAppState(instanceId: 'community_c', messagingPort: testPort);
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

    // A ينشئ مجموعة يملكها، ثم مجتمعًا يُدرِجها.
    final group = await deviceA.createGroup(
      name: 'مجموعة داخل المجتمع',
      memberInternalNumbers: [deviceB.identity.internalNumber],
    );
    final community = await deviceA.createCommunity(
      name: 'مجتمع الاختبار',
      memberInternalNumbers: [deviceB.identity.internalNumber, deviceC.identity.internalNumber],
      linkedConversationIds: [group.id],
    );

    expect(
      await _waitUntil(() => deviceB.communities.any((c) => c.id == community.id)),
      isTrue,
      reason: 'يجب أن تصل دعوة المجتمع لـB',
    );
    expect(
      await _waitUntil(() => deviceC.communities.any((c) => c.id == community.id)),
      isTrue,
      reason: 'يجب أن تصل دعوة المجتمع لـC',
    );

    final communityOnB = deviceB.communities.firstWhere((c) => c.id == community.id);
    expect(communityOnB.linkedConversationIds, [group.id]);
    expect(communityOnB.ownerInternalNumber, deviceA.identity.internalNumber);

    // C يغادر المجتمع — يجب أن يعرف A وB أن C لم يعد عضوًا.
    await deviceC.leaveCommunity(community.id);
    expect(deviceC.communities.any((c) => c.id == community.id), isFalse);

    expect(
      await _waitUntil(() {
        final onA = deviceA.communities.where((c) => c.id == community.id);
        return onA.isNotEmpty && !onA.first.memberInternalNumbers.contains(deviceC.identity.internalNumber);
      }),
      isTrue,
      reason: 'يجب أن يعرف A أن C غادر',
    );
    expect(
      await _waitUntil(() {
        final onB = deviceB.communities.where((c) => c.id == community.id);
        return onB.isNotEmpty && !onB.first.memberInternalNumbers.contains(deviceC.identity.internalNumber);
      }),
      isTrue,
      reason: 'يجب أن يعرف B أن C غادر أيضًا (وليس فقط A)',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
