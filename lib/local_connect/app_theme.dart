import 'package:flutter/material.dart';

/// أخضر واتساب المعروف (#25D366) — نفس بذرة الألوان (seed) للوضعين معًا،
/// فيبني Material 3 منها لوحة ألوان متّسقة (سطوح، حدود، نص...) بدل اختيار
/// كل لون يدويًا؛ هذا ما يضمن بقاء الوضع الداكن متناسقًا تلقائيًا مع أي
/// تعديل مستقبلي على لون الهوية الأساسي.
class AppTheme {
  static const Color seedColor = Color(0xFF25D366);

  static final ThemeData light = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light),
  );

  static final ThemeData dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark),
  );
}
