/// يزيل أي محرف "surrogate" مفرد (نصف زوج ترميز UTF-16 غير مكتمل) من نص
/// وارد من مصدر خارجي — اسم جهاز Wi-Fi Direct أو Bluetooth مثلًا، حيث
/// أبلغت بعض الأجهزة أسماءً معطوبة على مستوى نظام أندرويد نفسه (خارج
/// سيطرة هذا التطبيق).
///
/// نص فيه surrogate مفرد يبدو سليمًا وقت استلامه، لكن أي محاولة لاحقة
/// لترميزه UTF-8 (بثّ الحضور على الشبكة كل بضع ثوانٍ) أو عرضه في الواجهة
/// (Text) تفشل باستثناء "Invalid argument(s): string is not well-formed
/// UTF-16" — وبما أن اكتشاف الأجهزة يعيد بث نفس الاسم بشكل دوري، كان هذا
/// يتكرر في سجل الأخطاء كل بضع ثوانٍ دون توقف.
String sanitizeExternalText(String input) {
  final units = input.codeUnits;
  final buffer = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 < units.length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
        buffer.writeCharCode(unit);
        buffer.writeCharCode(units[i + 1]);
        i++;
      }
      // لا يتبعه low surrogate صالح — يُسقَط بصمت بدل أن يُبقيه معطوبًا.
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      // low surrogate بلا high surrogate قبله — يُسقَط أيضًا.
      continue;
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}
