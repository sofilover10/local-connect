import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_attach_test_');
    return dir.path;
  }
}

/// يغطي هذا الاختبار مسارين جديدين ومحفوفين بالمخاطر أُضيفا فوق البنية
/// الأساسية: (1) نقل ملف فعلي بالبايت عبر القناة نفسها المستخدمة للنص
/// (ترميز/فك ترميز base64)، و(2) مشاركة رقم الهاتف تلقائيًا عبر بطاقات
/// الحضور وامتصاصه في جهة اتصال محفوظة مسبقًا دون رقم.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('نقل ملف بالبايت + مشاركة رقم الهاتف تلقائيًا وامتصاصه في جهة اتصال قائمة', () async {
    const testPort = 45802;
    final deviceA = LocalConnectAppState(instanceId: 'share_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'share_b', messagingPort: testPort);

    await deviceA.init();
    await deviceB.init();
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    // انتظار حتى يكتشف الجهازان بعضهما.
    final discoveryDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(discoveryDeadline)) {
      final mutual = deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null &&
          deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber) != null;
      if (mutual) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // B يضيف A كجهة اتصال *قبل* أن يضبط A رقم هاتفه — يجب ألا يظهر رقم بعد.
    final conversationOnB = await deviceB.addContactFromPeer(
      deviceB.discovery.peerByInternalNumber(deviceA.identity.internalNumber)!,
    );
    expect(
      deviceB.contacts.firstWhere((c) => c.internalNumber == deviceA.identity.internalNumber).phoneNumber,
      isNull,
    );

    // الآن يضبط A رقم هاتفه؛ يجب أن يمتصّه B تلقائيًا من بطاقات الحضور
    // اللاحقة دون أي إجراء يدوي إضافي من B.
    await deviceA.updatePhoneNumber('0599-123-456');

    final phoneDeadline = DateTime.now().add(const Duration(seconds: 10));
    String? absorbedPhone;
    while (DateTime.now().isBefore(phoneDeadline)) {
      absorbedPhone = deviceB.contacts
          .firstWhere((c) => c.internalNumber == deviceA.identity.internalNumber)
          .phoneNumber;
      if (absorbedPhone != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    expect(absorbedPhone, '0599-123-456',
        reason: 'يجب أن يُمتَص رقم هاتف A تلقائيًا في جهة اتصال B الموجودة مسبقًا');

    // نقل ملف حقيقي: B يرسل ملفًا نصيًا معروف المحتوى إلى A، ونتأكد أن
    // البايتات المستلَمة على A مطابقة تمامًا للأصل.
    final sourceFile =
        File('${Directory.systemTemp.path}${Platform.pathSeparator}local_connect_test_upload.txt');
    const fileContent = 'محتوى تجريبي لاختبار نقل الملفات عبر LocalConnect — 1234567890';
    await sourceFile.writeAsString(fileContent);
    addTearDown(() {
      if (sourceFile.existsSync()) sourceFile.deleteSync();
    });

    await deviceB.sendAttachment(
      conversationId: conversationOnB.id,
      filePath: sourceFile.path,
      kind: MessageKind.file,
      mimeType: 'text/plain',
    );

    final conversationIdOnA = conversationOnB.id; // نفس المعرّف على الطرفين
    final fileDeadline = DateTime.now().add(const Duration(seconds: 10));
    ChatMessage? receivedOnA;
    while (DateTime.now().isBefore(fileDeadline)) {
      final messages = deviceA.messagesFor(conversationIdOnA);
      if (messages.isNotEmpty && messages.first.attachmentLocalPath != null) {
        receivedOnA = messages.first;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    expect(receivedOnA, isNotNull, reason: 'يجب أن يستلم A رسالة الملف من B');
    expect(receivedOnA!.kind, MessageKind.file);
    final receivedBytes = await File(receivedOnA.attachmentLocalPath!).readAsString();
    expect(receivedBytes, fileContent, reason: 'محتوى الملف المستلَم يجب أن يطابق الأصل تمامًا بالبايت');

    final sentMessageOnB = deviceB.messagesFor(conversationOnB.id).first;
    expect(sentMessageOnB.status, MessageStatus.delivered);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
