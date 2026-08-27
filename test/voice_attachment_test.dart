import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/models/message.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_voice_test_');
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

/// يغطي إصلاحًا لبلاغ فعلي: بطاقة الرسالة الصوتية كانت تعرض "00:00" لحظيًا
/// ثم تتحول للمدة الحقيقية، لأن الواجهة كانت تستخرج المدة من الملف عبر
/// المشغّل الصوتي (لا يُحمَّل إلا بعد أول ضغطة تشغيل) بدل استخدام المدة
/// المعروفة فعليًا وقت التسجيل. الإصلاح: [ChatMessage.attachmentDurationMs]
/// يُملأ من المُرسِل ويصل عبر الشبكة، فيُعرَض فورًا على الطرفين معًا.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('مدة الرسالة الصوتية المعروفة وقت التسجيل تصل فعليًا للطرف الآخر', () async {
    const testPort = 46602;
    final deviceA = LocalConnectAppState(instanceId: 'voice_a', messagingPort: testPort);
    final deviceB = LocalConnectAppState(instanceId: 'voice_b', messagingPort: testPort);
    addTearDown(() {
      deviceA.dispose();
      deviceB.dispose();
    });

    await deviceB.init();
    await deviceA.init();

    await _waitUntil(() => deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber) != null);
    final conversationOnA =
        await deviceA.addContactFromPeer(deviceA.discovery.peerByInternalNumber(deviceB.identity.internalNumber)!);

    final voiceFile =
        File('${Directory.systemTemp.path}${Platform.pathSeparator}local_connect_voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
    await voiceFile.writeAsBytes(List<int>.filled(500, 1));
    addTearDown(() {
      if (voiceFile.existsSync()) voiceFile.deleteSync();
    });

    final sent = await deviceA.sendAttachment(
      conversationId: conversationOnA.id,
      filePath: voiceFile.path,
      kind: MessageKind.voice,
      mimeType: 'audio/m4a',
      durationMs: 7000,
    );
    expect(sent, isTrue);

    // على المُرسِل نفسه، تظهر المدة فورًا محليًا دون انتظار أي شبكة.
    final onA = deviceA.messagesFor(conversationOnA.id).first;
    expect(onA.attachmentDurationMs, 7000);

    expect(
      await _waitUntil(() => deviceB.messagesFor(conversationOnA.id).any((m) => m.kind == MessageKind.voice)),
      isTrue,
      reason: 'يجب أن تصل الرسالة الصوتية لـB',
    );
    final onB = deviceB.messagesFor(conversationOnA.id).firstWhere((m) => m.kind == MessageKind.voice);
    expect(onB.attachmentDurationMs, 7000, reason: 'يجب أن تصل المدة الحقيقية (وليس صفرًا) لـB مباشرة');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('رفض إرسال ملف فارغ (0 بايت) بدل إرسال رسالة صوتية بلا محتوى', () async {
    const testPort = 46603;
    final deviceA = LocalConnectAppState(instanceId: 'voice_empty_a', messagingPort: testPort);
    addTearDown(() => deviceA.dispose());
    await deviceA.init();

    final emptyFile =
        File('${Directory.systemTemp.path}${Platform.pathSeparator}local_connect_empty_${DateTime.now().millisecondsSinceEpoch}.m4a');
    await emptyFile.writeAsBytes(const []);
    addTearDown(() {
      if (emptyFile.existsSync()) emptyFile.deleteSync();
    });

    // لا محادثة قائمة أصلًا هنا؛ الهدف فقط التأكد أن sendAttachment يرفض
    // الملف الفارغ نفسه قبل حتى محاولة بناء رسالة أو البحث عن محادثة.
    final sent = await deviceA.sendAttachment(
      conversationId: 'nonexistent',
      filePath: emptyFile.path,
      kind: MessageKind.voice,
      mimeType: 'audio/m4a',
      durationMs: 0,
    );
    expect(sent, isFalse, reason: 'يجب رفض ملف بحجم صفر بايت فورًا');
    expect(
      deviceA.errorLog.any((e) => e.contains('فارغ')),
      isTrue,
      reason: 'يجب تسجيل سبب الرفض في سجل الأخطاء',
    );
  });
}
