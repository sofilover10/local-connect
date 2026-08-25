import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/relay_service.dart';

/// يتحقق من خدمة المُرحِّل من طرف Flutter مباشرة، مقابل الخادم الحقيقي
/// المنشور فعليًا (chat.sofinet.cc) — وليس مقابل مضيف وهمي. الخادم نفسه
/// (Go) له اختبار تكامل مستقل في مستودعه الخاص؛ هذا يغطي تحديدًا أن غلاف
/// Dart (تسلسل/فك تسلسل الحمولة، اتصال WebSocket) يعمل بشكل صحيح معه.
///
/// يتطلب إنترنتًا فعليًا ليعمل — إن تعذّر الوصول، الاختبار سيفشل بوضوح
/// بدل التظاهر بالنجاح، فهذا سلوك مقصود (نتحقق من تكامل حقيقي لا وهمي).
void main() {
  test('التسجيل والاتصال وتبادل رسالة حية عبر المُرحِّل المركزي الحقيقي', () async {
    final unique = DateTime.now().millisecondsSinceEpoch;
    final numberA = 'LC-RTEST-A$unique';
    final numberB = 'LC-RTEST-B$unique';

    final relayA = RelayService();
    final relayB = RelayService();
    addTearDown(() async {
      await relayA.dispose();
      await relayB.dispose();
    });

    final registeredA = await relayA.register(internalNumber: numberA, displayName: 'Relay Test A');
    final registeredB = await relayB.register(internalNumber: numberB, displayName: 'Relay Test B');
    expect(registeredA, isTrue, reason: 'فشل تسجيل A لدى المُرحِّل — تحقق من الاتصال بالإنترنت');
    expect(registeredB, isTrue, reason: 'فشل تسجيل B لدى المُرحِّل — تحقق من الاتصال بالإنترنت');

    await relayA.connect(numberA);
    await relayB.connect(numberB);

    final connectDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(connectDeadline) && !(relayA.isConnected && relayB.isConnected)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(relayA.isConnected, isTrue, reason: relayA.lastError ?? 'لم يتصل A بالمُرحِّل');
    expect(relayB.isConnected, isTrue, reason: relayB.lastError ?? 'لم يتصل B بالمُرحِّل');

    Map<String, dynamic>? received;
    relayB.incoming.listen((payload) => received = payload);

    final sent = await relayA.send(
      to: numberB,
      payload: {
        'type': 'message',
        'id': 'relay-flutter-test-1',
        'senderInternalNumber': numberA,
        'text': 'رسالة اختبار عبر المُرحِّل من Flutter',
      },
    );
    expect(sent, isTrue);

    final receiveDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(receiveDeadline) && received == null) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    expect(received, isNotNull, reason: 'لم تصل الرسالة عبر المُرحِّل الحقيقي خلال المهلة');
    expect(received!['text'], 'رسالة اختبار عبر المُرحِّل من Flutter');
    expect(received!['senderInternalNumber'], numberA);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
