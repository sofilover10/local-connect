import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_scope.dart';
import '../models/diagnostic_check.dart';

/// شاشة "فحص الأخطاء": تفحص حالة الشبكة والاتصال فعليًا، وتحاول إصلاح أي
/// خدمة متوقفة تلقائيًا، وتعرض سجل الأخطاء غير المتوقَّعة التي التُقطت
/// أثناء تشغيل التطبيق بدل أن تسبب انهيارًا صامتًا.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DiagnosticCheck>? _checks;
  bool _running = false;
  String? _versionLabel;
  bool _startedInitialCheck = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _versionLabel = 'الإصدار ${info.version}+${info.buildNumber}');
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope.of(context) يعتمد على InheritedWidget، ولا يجوز استدعاؤه في
    // initState() (يرمي Flutter استثناءً صريحًا لهذا) — didChangeDependencies
    // هو المكان الصحيح لأول قراءة من هذا النوع عند إنشاء الودجت.
    if (!_startedInitialCheck) {
      _startedInitialCheck = true;
      _runChecks();
    }
  }

  Future<void> _runChecks() async {
    setState(() => _running = true);
    final appState = AppScope.of(context);
    final checks = await appState.runDiagnostics();
    if (!mounted) return;
    setState(() {
      _checks = checks;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('فحص الأخطاء والاتصال'),
            if (_versionLabel != null)
              Text(_versionLabel!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _running ? null : _runChecks,
            icon: const Icon(Icons.refresh),
            tooltip: 'إعادة الفحص والإصلاح',
          ),
        ],
      ),
      body: _running && _checks == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_running) const LinearProgressIndicator(),
                for (final check in _checks ?? const <DiagnosticCheck>[])
                  ListTile(
                    leading: Icon(
                      check.ok ? Icons.check_circle : Icons.error,
                      color: check.ok
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(check.label),
                    subtitle: Text(check.detail),
                    trailing: check.onFix == null
                        ? null
                        : TextButton(
                            onPressed: () async {
                              await check.onFix!();
                              if (mounted) unawaited(_runChecks());
                            },
                            child: const Text('إصلاح'),
                          ),
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('سجل الأخطاء الأخيرة', style: Theme.of(context).textTheme.titleMedium),
                ),
                AnimatedBuilder(
                  animation: appState,
                  builder: (context, _) {
                    if (appState.errorLog.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('لا توجد أخطاء مسجَّلة.'),
                      );
                    }
                    return Column(
                      children: [
                        for (final entry in appState.errorLog)
                          ListTile(dense: true, leading: const Icon(Icons.bug_report, size: 18), title: Text(entry)),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }
}
