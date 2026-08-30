/// نتيجة فحص واحد ضمن شاشة "فحص الأخطاء" (تشخيص الشبكة والاتصال).
class DiagnosticCheck {
  DiagnosticCheck({required this.label, required this.ok, required this.detail, this.onFix});

  final String label;
  final bool ok;
  final String detail;

  /// إجراء إصلاح مباشر اختياري (مثلًا فتح شاشة إعدادات صلاحية معيَّنة) —
  /// يظهر كزر عند فشل الفحص فقط. null إن لم يكن هناك إصلاح تلقائي ممكن.
  final Future<void> Function()? onFix;
}
