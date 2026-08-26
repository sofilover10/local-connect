import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/status_post.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_status_test_');
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('حالة نصية تُبَثّ لجهة اتصال فعليًا، ومشاهدتها تصل لصاحبها', () async {
    const testPort = 46202;
    final deviceA = LocalConnectAppState(instanceId: 'status_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'status_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    await deviceB.init();
    await deviceA.init();

    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null);
    await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);

    await deviceA.postStatus(text: 'مرحبًا من A', kind: StatusKind.text);

    expect(
      await _waitUntil(() => deviceB.statuses.any((s) => s.text == 'مرحبًا من A')),
      isTrue,
      reason: 'يجب أن تصل الحالة لـB فعليًا عبر الشبكة',
    );

    final statusOnB = deviceB.statuses.firstWhere((s) => s.text == 'مرحبًا من A');
    expect(statusOnB.authorInternalNumber, deviceA.identity.internalNumber);
    expect(statusOnB.isExpired, isFalse);

    await deviceB.markStatusViewed(statusOnB.id);

    expect(
      await _waitUntil(() {
        final statusOnA = deviceA.statuses.firstWhere((s) => s.id == statusOnB.id);
        return statusOnA.viewedBy.contains(deviceB.identity.internalNumber);
      }),
      isTrue,
      reason: 'يجب أن تصل مشاهدة B فعليًا لصاحبة الحالة A',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('حالة أقدم من 24 ساعة تُعتبَر منتهية', () {
    final fresh = StatusPost(
      id: '1',
      authorInternalNumber: 'LC-1',
      authorDisplayName: 'شخص',
      postedAt: DateTime.now(),
      text: 'حالة جديدة',
    );
    final old = StatusPost(
      id: '2',
      authorInternalNumber: 'LC-1',
      authorDisplayName: 'شخص',
      postedAt: DateTime.now().subtract(const Duration(hours: 25)),
      text: 'حالة قديمة',
    );

    expect(fresh.isExpired, isFalse);
    expect(old.isExpired, isTrue);
  });
}
