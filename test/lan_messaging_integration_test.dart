import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// بيئة `flutter test` لا توفر قنوات المنصّة الحقيقية، لذا نزوّد path_provider
/// بمسار مجلد مؤقت حقيقي على القرص بدل الاعتماد على قناة منصّة غير موجودة.
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_test_');
    return dir.path;
  }
}

/// اختبار تكامل حقيقي: يشغّل جهازين وهميين (نسختين من [LocalConnectAppState])
/// داخل نفس العملية، كل واحد بمقابس TCP/UDP فعلية على المضيف نفسه، للتأكد
/// أن الاكتشاف عبر الشبكة وتسليم الرسائل يعملان فعليًا وليس فقط أن الكود
/// يُصرَّف. هذا ما يمكن تشغيله على هذه البيئة لعدم توفر Visual Studio لبناء
/// تطبيق سطح مكتب فعلي، ولأن dart:io غير مدعوم على الويب.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('جهازان يكتشفان بعضهما ويتبادلان رسالة عبر الشبكة المحلية فعليًا', () async {
    final deviceA = LocalConnectAppState(instanceId: 'device_a');
    final deviceB = LocalConnectAppState(instanceId: 'device_b');

    await deviceA.init();
    await deviceB.init();

    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    // انتظار حتى يكتشف كل جهاز الآخر عبر بث UDP الدوري.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final aSeesB = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null;
      final bSeesA = deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber) != null;
      if (aSeesB && bSeesA) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    expect(
      deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber),
      isNotNull,
      reason: 'يُفترض أن يكتشف الجهاز A الجهاز B عبر بث الشبكة المحلية',
    );
    expect(
      deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber),
      isNotNull,
      reason: 'يُفترض أن يكتشف الجهاز B الجهاز A عبر بث الشبكة المحلية',
    );

    final conversationOnA = await deviceA.addContactFromPeer(
      deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!,
    );

    await deviceA.sendMessage(conversationId: conversationOnA.id, text: 'مرحبا من الجهاز A');

    final receiveDeadline = DateTime.now().add(const Duration(seconds: 10));
    List<ChatMessage> receivedOnB = [];
    while (DateTime.now().isBefore(receiveDeadline)) {
      final conversationId = deviceB.conversations
          .where((c) => c.peerInternalNumber == deviceA.identity.internalNumber)
          .map((c) => c.id);
      if (conversationId.isNotEmpty) {
        receivedOnB = deviceB.messagesFor(conversationId.first);
        if (receivedOnB.isNotEmpty) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    expect(receivedOnB, hasLength(1), reason: 'يُفترض أن تصل الرسالة فعليًا للجهاز B عبر TCP مباشر');
    expect(receivedOnB.first.text, 'مرحبا من الجهاز A');

    final sentMessage = deviceA.messagesFor(conversationOnA.id).first;
    expect(
      sentMessage.status,
      MessageStatus.delivered,
      reason: 'حالة الرسالة على الجهاز المُرسِل يجب أن تتحول إلى delivered بعد وصول الإقرار (ack)',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
