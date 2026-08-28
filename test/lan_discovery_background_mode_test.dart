import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/device_identity_service.dart';
import 'package:local_connect/local_connect/services/lan_discovery_service.dart';

/// يتأكد أن [LanDiscoveryService.setBackgroundMode] يُبطئ فعليًا معدَّل بث
/// بطاقة الحضور (وليس فقط تغييرًا تجميليًا لا أثر له)، عبر قياس عدد مرات
/// وصول بطاقات الحضور فعليًا لجهاز آخر على نفس الشبكة خلال نافذة زمنية
/// ثابتة، قبل وبعد التبديل للخلفية.
void main() {
  test('البث بالخلفية أبطأ فعليًا من البث بالمقدمة خلال نفس المدة', () async {
    final serviceA = LanDiscoveryService(
      udpPort: 45688,
      broadcastInterval: const Duration(milliseconds: 80),
      backgroundBroadcastInterval: const Duration(milliseconds: 400),
      staleTimeout: const Duration(seconds: 30),
    );
    final serviceB = LanDiscoveryService(
      udpPort: 45688,
      broadcastInterval: const Duration(seconds: 30),
      staleTimeout: const Duration(seconds: 30),
    );

    final identityA =
        DeviceIdentity(deviceId: 'device-a', internalNumber: 'A1', displayName: 'جهاز أ');
    final identityB =
        DeviceIdentity(deviceId: 'device-b', internalNumber: 'B1', displayName: 'جهاز ب');

    await serviceA.start(identity: identityA, tcpPort: 1);
    await serviceB.start(identity: identityB, tcpPort: 1);
    addTearDown(() async {
      await serviceA.stop();
      await serviceB.stop();
    });

    var foregroundUpdates = 0;
    final foregroundSub = serviceB.peersStream.listen((_) => foregroundUpdates++);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await foregroundSub.cancel();

    serviceA.setBackgroundMode(true);

    var backgroundUpdates = 0;
    final backgroundSub = serviceB.peersStream.listen((_) => backgroundUpdates++);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await backgroundSub.cancel();

    expect(
      foregroundUpdates,
      greaterThan(backgroundUpdates),
      reason: 'يُفترض أن يستقبل الجهاز B بطاقات حضور أكثر عندما يبث الجهاز A '
          'بالمعدَّل السريع (المقدمة) مقارنةً بالمعدَّل البطيء (الخلفية)',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));
}
