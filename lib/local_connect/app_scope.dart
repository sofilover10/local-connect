import 'package:flutter/widgets.dart';

import 'services/app_state.dart';

// يُعيد تصدير app_state.dart (وبالتالي كل الامتدادات extensions المُعرَّفة
// في ملفاتها الجزئية part — انظر app_state_communities.dart وغيرها) —
// بدون هذا، أي ملف يستورد AppScope فقط (نمط شائع في كل الشاشات) لن يرى
// دوال تلك الامتدادات رغم أن النوع LocalConnectAppState نفسه متاح له عرَضًا؛
// الامتدادات تحتاج استيرادًا فعليًا (مباشرًا أو عبر export) لا استخدامًا
// عرَضيًا للنوع فقط.
export 'services/app_state.dart';

/// يمرّر [LocalConnectAppState] لأي شاشة أسفل الشجرة دون الحاجة لحزمة
/// إدارة حالة خارجية، بنفس أسلوب InheritedNotifier المستخدم في مشروع rafah.
class AppScope extends InheritedNotifier<LocalConnectAppState> {
  const AppScope({super.key, required LocalConnectAppState state, required super.child})
      : super(notifier: state);

  static LocalConnectAppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!.notifier!;
  }
}
