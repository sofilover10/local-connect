import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_edit_test_');
    return dir.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('تعديل وحذف رسالة يصلان فعليًا للطرف الآخر عبر الشبكة', () async {
    const testPort = 45902;
    final deviceA = LocalConnectAppState(instanceId: 'edit_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'edit_b', messagingPort: testPort);

    await deviceA.init();
    await deviceB.init();
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    final discoveryDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(discoveryDeadline)) {
      final mutual = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null &&
          deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber) != null;
      if (mutual) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final conversationOnA = await deviceA.addContactFromPeer(
      deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!,
    );
    final conversationId = conversationOnA.id;

    await deviceA.sendMessage(conversationId: conversationId, text: 'رسالة أصلية');

    Future<ChatMessage?> waitFor(
      LocalConnectAppState device,
      bool Function(ChatMessage) predicate, {
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final match = device.messagesFor(conversationId).where(predicate);
        if (match.isNotEmpty) return match.first;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      return null;
    }

    final receivedOriginal = await waitFor(deviceB, (m) => m.text == 'رسالة أصلية');
    expect(receivedOriginal, isNotNull, reason: 'يجب أن تصل الرسالة الأصلية إلى B أولًا');
    final messageId = receivedOriginal!.id;

    // التعديل: يُطبَّق محليًا على A فورًا، ويجب أن يصل لـB عبر الشبكة.
    await deviceA.editMessage(conversationId: conversationId, messageId: messageId, newText: 'رسالة مُعدَّلة');
    final editedOnA = deviceA.messagesFor(conversationId).firstWhere((m) => m.id == messageId);
    expect(editedOnA.text, 'رسالة مُعدَّلة');
    expect(editedOnA.editedAt, isNotNull);

    final editedOnB = await waitFor(deviceB, (m) => m.id == messageId && m.text == 'رسالة مُعدَّلة');
    expect(editedOnB, isNotNull, reason: 'يجب أن يصل التعديل فعليًا إلى B عبر الشبكة');
    expect(editedOnB!.editedAt, isNotNull);

    // الحذف للجميع: يُطبَّق محليًا فورًا، ويجب أن يصل لـB أيضًا.
    await deviceA.deleteMessage(conversationId: conversationId, messageId: messageId, forEveryone: true);
    final deletedOnA = deviceA.messagesFor(conversationId).firstWhere((m) => m.id == messageId);
    expect(deletedOnA.isDeleted, isTrue);

    final deletedOnB = await waitFor(deviceB, (m) => m.id == messageId && m.isDeleted);
    expect(deletedOnB, isNotNull, reason: 'يجب أن يصل الحذف فعليًا إلى B عبر الشبكة');
  }, timeout: const Timeout(Duration(seconds: 40)));

  // يتحقق هذا الاختبار من حارس سلامة بيانات فقط: طلب حذف/تعديل بحمولة
  // senderInternalNumber لا يطابق ما هو مخزَّن فعليًا مع الرسالة يجب أن
  // يُرفَض. هذا **ليس** إثبات هوية حقيقيًا — أي جهاز على الشبكة يقدر أصلًا
  // يدّعي أي senderInternalNumber يريده (لا يوجد تحقق تشفيري بعد)، فهذا
  // الحارس يمنع فقط حالة عدم اتساق بين المُرسِل المُدَّعى والمُرسِل
  // الأصلي المسجَّل، لا انتحال هوية طرف شرعي فعليًا.
  test('رفض حذف/تعديل حمولة تشير لمُرسِل مختلف عن المسجَّل مع الرسالة الأصلية', () async {
    const testPort = 45903;
    final device = LocalConnectAppState(instanceId: 'edit_security_target', messagingPort: testPort);
    await device.init();
    addTearDown(device.dispose);

    // نستقبل رسالة حقيقية أولًا لإنشاء سجل نعرف صاحبه المسجَّل محليًا.
    const legitimateSender = 'LC-777777';

    final socket1 = await Socket.connect('127.0.0.1', device.socket.boundPort);
    socket1.write(
      '${jsonEncode({
            'type': 'message',
            'id': 'original-message-id',
            'senderInternalNumber': legitimateSender,
            'text': 'رسالة من صاحبها الحقيقي',
            'sentAt': DateTime.now().toIso8601String(),
            'kind': 'text',
          })}\n',
    );
    await socket1.flush();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await socket1.close();

    final realConversationId =
        device.conversations.where((c) => c.peerInternalNumber == legitimateSender).map((c) => c.id).first;
    expect(realConversationId, isNotEmpty);
    final original = device.messagesFor(realConversationId).firstWhere((m) => m.id == 'original-message-id');
    expect(original.text, 'رسالة من صاحبها الحقيقي');

    // الآن جهاز خبيث يدّعي أنه طرف آخر تمامًا (لكن يحسب نفس معرّف المحادثة
    // لأنه لا يعرف إلا رقم الضحية) ويحاول حذف رسالة ليست له.
    final socket2 = await Socket.connect('127.0.0.1', device.socket.boundPort);
    socket2.write(
      '${jsonEncode({
            'type': 'delete_message',
            'id': 'original-message-id',
            'senderInternalNumber': 'LC-999999',
          })}\n',
    );
    await socket2.flush();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await socket2.close();

    final stillThere = device.messagesFor(realConversationId).firstWhere((m) => m.id == 'original-message-id');
    expect(stillThere.isDeleted, isFalse,
        reason: 'يجب ألا يُحذَف سجل رسالة عبر ادّعاء هوية مُرسِل مختلف عن مؤلفها الأصلي');
  }, timeout: const Timeout(Duration(seconds: 20)));
}
