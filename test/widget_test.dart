import 'package:flutter_test/flutter_test.dart';

import 'package:local_connect/main.dart';
import 'package:local_connect/local_connect/services/app_state.dart';

void main() {
  testWidgets('التطبيق يقلع ويصل لشاشة تجهيز الاتصال', (WidgetTester tester) async {
    // LocalConnectApp يتولى التخلص من appState بنفسه في dispose() الخاص به
    // عند إزالة الودجت في نهاية الاختبار، فلا حاجة للتخلص منه هنا أيضًا.
    final appState = LocalConnectAppState(instanceId: 'widget_test');

    await tester.pumpWidget(LocalConnectApp(appState: appState));

    // قبل انتهاء init() يجب أن تظهر شاشة "جارٍ تجهيز الاتصال".
    expect(find.text('جارٍ تجهيز الاتصال على الشبكة المحلية...'), findsOneWidget);
  });
}
