/// نتيجة فحص واحد ضمن شاشة "فحص الأخطاء" (تشخيص الشبكة والاتصال).
class DiagnosticCheck {
  DiagnosticCheck({required this.label, required this.ok, required this.detail});

  final String label;
  final bool ok;
  final String detail;
}
