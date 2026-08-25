import 'package:flutter/material.dart';

import '../app_scope.dart';

Future<void> showEditProfileDialog(BuildContext context) async {
  final appState = AppScope.of(context);
  final nameController = TextEditingController(text: appState.identity.displayName);
  final phoneController = TextEditingController(text: appState.identity.phoneNumber ?? '');

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('ملفك الشخصي'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'اسمك المعروض'),
          ),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'رقم هاتفك (اختياري)',
              helperText: 'إن ضبطته، يظهر تلقائيًا لأي شخص تتواصل معه ويُحفَظ لديه',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
      ],
    ),
  );

  if (result != true) return;

  final newName = nameController.text.trim();
  if (newName.isNotEmpty) await appState.updateDisplayName(newName);
  await appState.updatePhoneNumber(phoneController.text.trim());
}
