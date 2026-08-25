import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/app_state.dart';
import 'package:local_connect/main.dart';
import 'package:package_info_plus_platform_interface/package_info_data.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('local_connect_nav_test_');
    return dir.path;
  }
}

class _FakePackageInfoPlatform extends PackageInfoPlatform {
  @override
  Future<PackageInfoData> getAll({String? baseUrl}) async => PackageInfoData(
        appName: 'local_connect',
        packageName: 'com.sofilover10.localconnect.local_connect',
        version: '0.0.0',
        buildNumber: '0',
        buildSignature: '',
      );
}

/// يغطي هذا الاختبار خطأ حقيقيًا حدث فعليًا: `AppScope` كانت تلفّ `home:`
/// فقط بدل `MaterialApp` بالكامل، فأي شاشة تُفتح عبر `Navigator.push`
/// (كشاشة المحادثة وشاشة فحص الأخطاء) تُصبح مسارًا شقيقًا لـ home ضمن
/// Navigator الجذري لـMaterialApp، وليست وصيلة تحته فعليًا — فيفشل
/// `AppScope.of(context)` بصمت في وضع release (لأن `assert` لا يعمل هناك)
/// برسالة "Null check operator used on a null value". لا اختبار سابق كان
/// يفتح شاشة فعلية عبر Navigator.push، فمرّ هذا الخطأ دون أن يُكتشَف.
///
/// يستخدم `tester.runAsync` لأن `LocalConnectAppState.init()` يفتح مقابس
/// شبكة حقيقية (dart:io)، والتي لا تعمل بشكل صحيح مع الساعة الوهمية
/// الافتراضية لـ`testWidgets`. كما يتجنّب `pumpAndSettle()` عمدًا لأن شاشة
/// البدء تحتوي مؤشر تحميل دائري متحرك بلا نهاية يجعله يُعلَّق إلى الأبد.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();
  PackageInfoPlatform.instance = _FakePackageInfoPlatform();

  // لا علاقة لهاتين القناتين بالخطأ الذي يغطيه هذا الاختبار (AppScope) —
  // لكن AppState.init() يشغّل بلوتوث دائمًا، وChatScreen ينشئ AudioRecorder
  // دائمًا، وكلاهما بلا تطبيق حقيقي مسجَّل تحت flutter test، فنموّه بأبسط
  // استجابة ممكنة لتفادي ضجيج MissingPluginException غير المتعلّق بما نختبره.
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('local_connect/bluetooth/data'), (_) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('local_connect/bluetooth/devices'), (_) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('local_connect/bluetooth'), (_) async => false);
  messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);

  Future<void> waitUntilReady(WidgetTester tester, LocalConnectAppState appState) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!appState.isReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(appState.isReady, isTrue, reason: 'appState.init() لم تنتهِ خلال المهلة');
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('فتح محادثة عبر Navigator.push لا يُسقِط الشاشة بخطأ AppScope', (tester) async {
    await tester.runAsync(() async {
      // LocalConnectApp يتولى التخلص من appState بنفسه عند إزالة الودجت
      // في نهاية الاختبار — التخلص منه هنا أيضًا يسبب استدعاء dispose()
      // مرتين على نفس الكائن.
      final appState = LocalConnectAppState(instanceId: 'nav_test_chat', messagingPort: 45803);

      await tester.pumpWidget(LocalConnectApp(appState: appState));
      await tester.pump();
      await waitUntilReady(tester, appState);

      await appState.addContact(internalNumber: 'LC-999999', displayName: 'صديق تجريبي');
      await tester.pump();

      expect(find.text('صديق تجريبي'), findsOneWidget);
      await tester.tap(find.text('صديق تجريبي'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // إتمام انتقال الصفحة

      // يجب أن تظهر شاشة المحادثة فعليًا (حقل الكتابة)، لا نص خطأ مكانها.
      expect(find.text('اكتب رسالة...'), findsOneWidget);
      expect(find.textContaining('حدث خطأ'), findsNothing);
      expect(find.textContaining('Null check operator'), findsNothing);
    });
  });

  testWidgets('فتح شاشة فحص الأخطاء عبر Navigator.push لا يُسقِط الشاشة', (tester) async {
    await tester.runAsync(() async {
      final appState = LocalConnectAppState(instanceId: 'nav_test_diag', messagingPort: 45804);

      await tester.pumpWidget(LocalConnectApp(appState: appState));
      await tester.pump();
      await waitUntilReady(tester, appState);

      await tester.tap(find.byTooltip('فحص الأخطاء والاتصال'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('فحص الأخطاء والاتصال'), findsOneWidget);
      expect(find.textContaining('حدث خطأ'), findsNothing);
      expect(find.textContaining('Null check operator'), findsNothing);
    });
  });
}
