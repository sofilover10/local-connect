import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_malicious_test_');
    return dir.path;
  }
}

/// يتحقق أن جهازًا آخر على الشبكة لا يستطيع حقن قيمة `senderInternalNumber`
/// تحتوي عناصر مسار (`../`) لإجبار التطبيق على الكتابة خارج مجلد المرفقات
/// المخصَّص — يجب أن تُرفَض الرسالة كاملة بدل معالجتها.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('رفض رسالة واردة برقم داخلي يحتوي عناصر اجتياز مسار (path traversal)', () async {
    const testPort = 45902;
    final device = LocalConnectAppState(instanceId: 'malicious_target', messagingPort: testPort);
    await device.init();
    addTearDown(device.dispose);

    expect(device.socket.isActive, isTrue, reason: 'يجب أن يعمل خادم الاستقبال لإجراء هذا الاختبار');

    final maliciousPayload = jsonEncode({
      'type': 'message',
      'id': 'evil-message-id',
      'conversationId': '../../outside',
      'senderInternalNumber': '../../../evil',
      'text': 'محاولة اختراق',
      'sentAt': DateTime.now().toIso8601String(),
      'kind': 'file',
      'attachmentFileName': '../../../../evil_escape.txt',
      'data': base64Encode(utf8.encode('لو نجحت هذه الكتابة فهناك ثغرة اجتياز مسار')),
    });

    final socket = await Socket.connect('127.0.0.1', device.socket.boundPort);
    socket.write('$maliciousPayload\n');
    await socket.flush();

    // نمهل معالجة الحمولة وقتًا كافيًا، ثم نتأكد أنها رُفضت ولم تُنشئ أي
    // محادثة أو رسالة جديدة، وسُجِّلت في سجل الأخطاء بدل أن تُقبَل بصمت.
    await Future<void>.delayed(const Duration(seconds: 1));
    await socket.close();

    expect(device.conversations, isEmpty,
        reason: 'يجب ألا تُنشَأ أي محادثة من حمولة تحتوي رقمًا داخليًا غير آمن');
    expect(
      device.errorLog.any((entry) => entry.contains('رسالة واردة')),
      isTrue,
      reason: 'يجب تسجيل رفض الحمولة غير الآمنة في سجل الأخطاء',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));
}
