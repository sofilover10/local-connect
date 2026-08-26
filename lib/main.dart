import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'local_connect/app_scope.dart';
import 'local_connect/screens/call_screen.dart';
import 'local_connect/screens/group_call_screen.dart';
import 'local_connect/screens/home_screen.dart';
import 'local_connect/services/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // بعض حزم intl (DateFormat) ترمي استثناءً إن استُخدمت مع لغة نظام غير
  // en_US دون تهيئة بيانات تلك اللغة أولًا — الواجهة هنا عربية دائمًا
  // (locale: ar بالأسفل)، فيجب تهيئتها قبل أي استخدام لـ DateFormat.
  await initializeDateFormatting();

  final appState = LocalConnectAppState();

  // يُنشأ appState قبل runApp حتى يمكن لمعالجات الأخطاء العامة أدناه
  // تسجيل أي خطأ غير متوقَّع في سجل الأخطاء الظاهر بشاشة "فحص الأخطاء"،
  // بدل أن يختفي الخطأ في الطرفية فقط أو يُسقِط التطبيق بصمت.
  FlutterError.onError = (FlutterErrorDetails details) {
    appState.recordError('خطأ واجهة', details.exceptionAsString());
    FlutterError.presentError(details);
  };

  // بدون هذا، أي خطأ أثناء بناء واجهة يُستبدَل بمربّع رمادي فارغ تمامًا في
  // إصدارات release (لا رسالة، لا شيء) — يجعل تشخيص المشكلة من بلاغ
  // المستخدم مستحيلًا. الآن يظهر نص الخطأ نفسه مكان الودجت المعطوبة.
  ErrorWidget.builder = (FlutterErrorDetails details) => _CrashDetails(details: details);

  runZonedGuarded(
    () => runApp(LocalConnectApp(appState: appState)),
    (error, stackTrace) => appState.recordError('خطأ غير متوقَّع', error),
  );
}

class _CrashDetails extends StatelessWidget {
  const _CrashDetails({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.red.shade50,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      child: Text(
        'حدث خطأ في هذه الشاشة:\n${details.exceptionAsString()}',
        style: const TextStyle(color: Colors.red, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class LocalConnectApp extends StatefulWidget {
  const LocalConnectApp({super.key, required this.appState});

  final LocalConnectAppState appState;

  @override
  State<LocalConnectApp> createState() => _LocalConnectAppState();
}

class _LocalConnectAppState extends State<LocalConnectApp> {
  late final Future<void> _initFuture = widget.appState.init();

  @override
  void dispose() {
    widget.appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AppScope يجب أن يلفّ MaterialApp بالكامل، وليس home: فقط — أي شاشة
    // تُفتح لاحقًا عبر Navigator.push تُضاف كمسار شقيق ضمن نفس Navigator
    // الداخلي لـMaterialApp (وليست وصيلة تحت home فعليًا)، فلن يجدها
    // AppScope.of(context) إن لم يكن أعلى من MaterialApp نفسه — وهذا بالضبط
    // ما كان يسبب "Null check operator used on a null value" عند فتح أي
    // محادثة (ChatScreen مبنية عبر Navigator.push).
    return AppScope(
      state: widget.appState,
      child: MaterialApp(
        title: 'LocalConnect',
        locale: const Locale('ar'),
        // أخضر واتساب المعروف (#25D366) — هوية بصرية مألوفة لمستخدمي تطبيقات
        // المحادثة الشائعة بدل الأخضر المزرق (teal) الافتراضي السابق.
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF25D366))),
        // builder يلفّ كل شجرة المسارات (Navigator) — هذا يجعل شاشة المكالمة
        // تظهر فوق أي شاشة حالية فور وصول عرض مكالمة، بدل الحاجة لدفعها
        // (push) من داخل كل شاشة على حدة أو تفويت اتصال وارد أثناء التصفّح.
        builder: (context, child) => Stack(
          children: [
            ?child,
            CallOverlay(callService: widget.appState.callService),
            GroupCallOverlay(groupCallService: widget.appState.groupCallService),
          ],
        ),
        home: FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _StartupScreen();
            }
            return const HomeScreen();
          },
        ),
      ),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('جارٍ تجهيز الاتصال على الشبكة المحلية...'),
          ],
        ),
      ),
    );
  }
}
