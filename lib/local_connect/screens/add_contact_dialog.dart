import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;

import '../app_scope.dart';
import 'chat_screen.dart';

/// إضافة جهة اتصال يدويًا برقمها الداخلي (أو رقم هاتفها إن اتُّفق عليه)،
/// لاستخدامها لاحقًا حين يظهر صاحب الرقم على الشبكة المحلية.
///
/// حقل عنوان IP اختياري: إن لم يظهر الطرف الآخر تلقائيًا في "أجهزة قريبة"
/// (مثلًا بسبب إعدادات شبكة تمنع بث الاكتشاف)، يمكن إدخال عنوانه المحلي
/// يدويًا (يظهر في إعدادات Wi-Fi على جهازه، أو في شاشة "فحص الأخطاء" هنا)
/// لإرسال الرسائل مباشرة إليه رغم ذلك.
///
/// زر "اختيار من جهات الاتصال" يملأ الاسم ورقم الهاتف تلقائيًا من دفتر
/// جهات اتصال الهاتف الفعلي — لكنه **لا** يكتشف رقمه الداخلي تلقائيًا: لا
/// يوجد خادم مركزي يربط أرقام الهواتف بأرقام LocalConnect (بخلاف واتساب
/// مثلًا)، فيبقى إدخال الرقم الداخلي (أو اكتشافه عبر Wi-Fi/بلوتوث) ضروريًا.
Future<void> showAddContactDialog(BuildContext context) async {
  final numberController = TextEditingController();
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  Future<void> pickFromPhoneContacts(BuildContext dialogContext) async {
    try {
      final picked = await fc.FlutterContacts.openExternalPick();
      if (picked == null) return;
      nameController.text = picked.displayName;
      if (picked.phones.isNotEmpty) phoneController.text = picked.phones.first.number;
    } catch (error) {
      if (!dialogContext.mounted) return;
      ScaffoldMessenger.of(dialogContext)
          .showSnackBar(SnackBar(content: Text('تعذّر فتح جهات الاتصال: $error')));
    }
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('إضافة جهة اتصال'),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () => pickFromPhoneContacts(context),
                icon: const Icon(Icons.contacts),
                label: const Text('اختيار من جهات الاتصال'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: numberController,
                decoration: const InputDecoration(labelText: 'الرقم الداخلي (مثال: LC-123456)'),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'أدخل الرقم الداخلي' : null,
              ),
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'الاسم المعروض'),
                validator: (value) => (value == null || value.trim().isEmpty) ? 'أدخل اسمًا' : null,
              ),
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)'),
                keyboardType: TextInputType.phone,
              ),
              TextFormField(
                controller: addressController,
                decoration: const InputDecoration(
                  labelText: 'عنوان IP (اختياري)',
                  helperText: 'أدخله فقط إذا لم يظهر الجهاز تلقائيًا في "أجهزة قريبة"',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  final trimmed = value?.trim() ?? '';
                  if (trimmed.isEmpty) return null;
                  return InternetAddress.tryParse(trimmed) == null ? 'عنوان IP غير صالح' : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Navigator.pop(context, true);
          },
          child: const Text('إضافة'),
        ),
      ],
    ),
  );

  if (result != true || !context.mounted) return;

  final manualAddress = addressController.text.trim();
  final phoneNumber = phoneController.text.trim();
  final conversation = await AppScope.of(context).addContact(
    internalNumber: numberController.text.trim(),
    displayName: nameController.text.trim(),
    phoneNumber: phoneNumber.isEmpty ? null : phoneNumber,
    manualAddress: manualAddress.isEmpty ? null : manualAddress,
  );

  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
}
