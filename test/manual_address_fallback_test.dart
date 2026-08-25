import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_manual_test_');
    return dir.path;
  }
}

/// يغطي هذا الاختبار الحالة التي أبلغ عنها المستخدم فعليًا: جهازان على نفس
/// الشبكة لكن اكتشاف UDP لا يجد أحدهما الآخر إطلاقًا (مثلًا بسبب عزل بين
/// أجهزة الشبكة). التأكد أن إدخال عنوان IP يدويًا يكفي وحده لإيصال الرسالة،
/// دون أي اعتماد على نجاح الاكتشاف التلقائي.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('إرسال رسالة عبر عنوان IP يدوي عندما لا يكتشف الجهازان بعضهما إطلاقًا', () async {
    // منفذ مختلف عن الافتراضي (45602) حتى لا يتنافس مع ملفات اختبار أخرى
    // (مثل lan_messaging_integration_test.dart) قد تعمل بالتوازي على نفس
    // المضيف وتستخدم المنفذ الافتراضي هي الأخرى.
    const testPort = 45702;
    final deviceA = LocalConnectAppState(instanceId: 'manual_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'manual_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    // يبدأ B أولًا حتى يحجز منفذ الاستقبال الثابت (preferredPort)، تمامًا
    // كما سيكون الحال بين جهازين حقيقيين مختلفين على الشبكة (لكل منهما
    // مضيفه الخاص، فلا تنافس حقيقي على المنفذ). A سيتراجع تلقائيًا لمنفذ
    // عشوائي بما أن الاختبارين يتشاركان نفس المضيف هنا.
    await deviceB.init();
    await deviceA.init();

    expect(
      deviceB.socket.boundPort,
      deviceA.socket.preferredPort,
      reason: 'B يجب أن يحصل على المنفذ الثابت الذي سيستهدفه A عبر الاتصال اليدوي',
    );

    // رقم داخلي وهمي لا يمكن أن يظهر عبر الاكتشاف التلقائي أبدًا؛ يحاكي
    // فشل UDP الكامل مع بقاء اتصال TCP المباشر ممكنًا.
    const fakeInternalNumber = 'LC-000000-NEVER-DISCOVERED';
    expect(deviceA.discovery.peerByInternalNumber(fakeInternalNumber), isNull);

    final conversation = await deviceA.addContact(
      internalNumber: fakeInternalNumber,
      displayName: 'جهاز غير مكتشَف',
      manualAddress: '127.0.0.1',
    );

    await deviceA.sendMessage(conversationId: conversation.id, text: 'رسالة عبر IP يدوي');

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final sent = deviceA.messagesFor(conversation.id).first;
      if (sent.status != MessageStatus.queued) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    final sentMessage = deviceA.messagesFor(conversation.id).first;
    expect(
      sentMessage.status,
      MessageStatus.delivered,
      reason: 'يجب أن تُسلَّم الرسالة عبر العنوان اليدوي رغم عدم اكتشاف الطرف الآخر إطلاقًا',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
