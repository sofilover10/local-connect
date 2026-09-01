import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_test_');
    return dir.path;
  }
}

/// يتأكد أن أنواع إشارات تحويل الفيديو الجديدة (call_video_upgrade_*،
/// call_renegotiate_*) تُوجَّه فعليًا إلى CallService.handleSignal، لا
/// تسقط في المسار الافتراضي في _handleIncomingWire الذي يُعامِلها كرسالة
/// محادثة عادية — وبما أنها بلا حقل 'text'، كانت تُرفَض بصمت هناك
/// (recordError فقط) قبل أن تصل لـ CallService إطلاقًا. هذا هو السبب
/// الجذري الفعلي وراء عدم وصول طلبات التحويل للفيديو للطرف الآخر مطلقًا.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('حمولات إشارات تحويل الفيديو لا تُرفَض كرسالة محادثة غير صالحة', () async {
    final deviceA = LocalConnectAppState(instanceId: 'call_routing_a');
    final deviceB = LocalConnectAppState(instanceId: 'call_routing_b');
    await deviceA.init();
    await deviceB.init();
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final aSeesB = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null;
      if (aSeesB) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final peerB = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber);
    expect(peerB, isNotNull, reason: 'يجب أن يكتشف الجهاز A الجهاز B عبر الشبكة المحلية أولًا');

    for (final type in [
      'call_video_upgrade_request',
      'call_video_upgrade_response',
      'call_renegotiate_offer',
      'call_renegotiate_answer',
    ]) {
      deviceB.errorLog.clear();
      final delivered = await deviceA.socket.sendDirect(
        address: peerB!.address,
        port: peerB.tcpPort,
        payload: {
          'type': type,
          'id': 'fake-call-id',
          'senderInternalNumber': deviceA.identity.internalNumber,
          'accepted': true,
          'sdp': 'v=0',
        },
      );
      expect(delivered, isTrue, reason: 'يجب أن تصل الحمولة فعليًا ($type)');

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        deviceB.errorLog.any((e) => e.contains('حمولة غير صالحة')),
        isFalse,
        reason: 'نوع $type يجب أن يُوجَّه إلى CallService، لا يُعامَل كرسالة محادثة عادية',
      );
    }
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('عرض مكالمة قديم (مخزَّن لدى المُرحِّل) يُرفَض ولا يُشغِّل رنينًا وهميًا', () async {
    final deviceA = LocalConnectAppState(instanceId: 'stale_offer_a');
    final deviceB = LocalConnectAppState(instanceId: 'stale_offer_b');
    await deviceA.init();
    await deviceB.init();
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final peerB = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber);
    expect(peerB, isNotNull, reason: 'يجب أن يكتشف الجهاز A الجهاز B عبر الشبكة المحلية أولًا');

    // يحاكي عرضًا أُرسل قبل 5 دقائق وخزّنه المُرحِّل ثم سلّمه متأخرًا عند
    // عودة الاتصال — كان سابقًا يُرنّ الجهاز لمكالمة ميّتة وتُسجَّل كمكالمة
    // فائتة وهمية.
    final delivered = await deviceA.socket.sendDirect(
      address: peerB!.address,
      port: peerB.tcpPort,
      payload: {
        'type': 'call_offer',
        'id': 'stale-call-id',
        'senderInternalNumber': deviceA.identity.internalNumber,
        'callerDisplayName': 'قديم',
        'mediaType': 'audio',
        'sdp': 'v=0',
        'sentAt': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
      },
    );
    expect(delivered, isTrue, reason: 'يجب أن تصل الحمولة نفسها عبر الشبكة');

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      deviceB.callService.currentCall,
      isNull,
      reason: 'عرض أقدم من مهلة الرنين يجب ألا يُنشئ مكالمة واردة إطلاقًا',
    );
    expect(
      deviceB.errorLog.any((e) => e.contains('تجاهُل call_offer قديم')),
      isTrue,
      reason: 'يجب أن يُسجَّل سبب التجاهل في السجل التشخيصي',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
