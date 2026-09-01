import 'dart:io';

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

  test('انقطاع الخادم يُكشَف ويُعاد الاتصال تلقائيًا عند عودته — بلا تدخّل ولا إعادة تشغيل للتطبيق', () async {
    // خادم WebSocket محلي صامت — يحاكي المُرحِّل. هذا الاختبار يغطّي جوهر
    // مشكلة "بيانات الجوال تتوقف حتى أعيد فتح التطبيق": يجب أن يُكشَف موت
    // القناة ويُعاد بناؤها تلقائيًا. ملاحظة: المقابس المُرقّاة (upgraded)
    // تنفصل عن HttpServer فلا يغلقها server.close() — لذلك نحتفظ بها
    // ونغلقها صراحة لمحاكاة موت الخادم.
    final activeSockets = <WebSocket>[];
    Future<HttpServer> startServer(int port) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      server.listen((request) async {
        if (request.uri.path == '/ws') {
          final socket = await WebSocketTransformer.upgrade(request);
          activeSockets.add(socket);
          socket.listen((_) {});
        }
      });
      return server;
    }

    var server = await startServer(0);
    final port = server.port;
    final relay = RelayService(host: '127.0.0.1', port: port, secure: false);
    addTearDown(() async {
      await relay.dispose();
      await server.close(force: true);
    });

    await relay.connect('LC-TEST-RECONNECT');
    expect(relay.isConnected, isTrue, reason: relay.lastError ?? 'فشل الاتصال الأول');

    // channel.ready قد يكتمل لدى العميل قبل أن ينتهي معالج الخادم من تسجيل
    // المقبس المُرقّى (سباق لحظي) — انتظر ظهوره وإلا أغلقنا "صفر" مقابس.
    final socketDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (activeSockets.isEmpty && DateTime.now().isBefore(socketDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(activeSockets, isNotEmpty, reason: 'الخادم لم يسجّل أي اتصال WebSocket وارد');

    // موت مفاجئ للخادم — يجب أن يصل onDone ويُسقِط حالة الاتصال.
    for (final socket in activeSockets) {
      await socket.close();
    }
    await server.close(force: true);
    final dropDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(dropDeadline) && relay.isConnected) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(relay.isConnected, isFalse, reason: 'لم يُكشَف انقطاع الخادم إطلاقًا');

    // عودة الخادم على نفس المنفذ — يجب أن يلتقطها backoff التصاعدي وحده
    // (أول محاولة بعد ثانيتين) دون أي استدعاء خارجي.
    server = await startServer(port);
    final recoverDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(recoverDeadline) && !relay.isConnected) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(relay.isConnected, isTrue,
        reason: 'لم يُعَد الاتصال تلقائيًا بعد عودة الخادم: ${relay.lastError}');
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('ensureConnected يبدأ إعادة اتصال فورًا بدل انتظار backoff الطويل', () async {
    final relay = RelayService(host: '127.0.0.1', port: 9, secure: false); // منفذ ميّت
    addTearDown(relay.dispose);

    await relay.connect('LC-TEST-ENSURE');
    expect(relay.isConnected, isFalse);
    expect(relay.lastError, isNotNull);

    // مباشرةً بعد الفشل يكون backoff مجدولًا؛ ensureConnected يجب أن يختصره
    // بمحاولة فورية (تفشل هنا أيضًا — المنفذ ميّت — لكن lastError يتحدّث،
    // أي المحاولة حدثت فعلًا الآن لا بعد ثوانٍ).
    relay.lastError = null;
    relay.ensureConnected();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) && relay.lastError == null) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(relay.lastError, isNotNull,
        reason: 'ensureConnected يجب أن يحاول فورًا (فشل سريع هنا متوقَّع — المنفذ ميّت)');
  }, timeout: const Timeout(Duration(seconds: 15)));
}
