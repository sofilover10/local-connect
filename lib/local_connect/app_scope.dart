import 'package:flutter/widgets.dart';

import 'services/app_state.dart';

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
