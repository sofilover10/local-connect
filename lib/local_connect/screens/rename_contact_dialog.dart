import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;

import '../app_scope.dart';
import '../models/conversation.dart';

/// يعيد تسمية جهة اتصال قائمة أصلًا، إما يدويًا أو بربطها بجهة من دفتر
/// جهات اتصال الهاتف الفعلي (نفس زر "اختيار من جهات الاتصال" المستخدم عند
/// الإضافة، لكن هنا لتحديث اسم/رقم جهة موجودة بدل إنشاء واحدة جديدة).
Future<void> showRenameContactDialog(BuildContext context, Conversation conversation) async {
  final nameController = TextEditingController(text: conversation.peerDisplayName);
  String? pickedPhoneNumber;

  Future<void> pickFromPhoneContacts(BuildContext dialogContext, void Function(void Function()) setState) async {
    try {
      final picked = await fc.FlutterContacts.openExternalPick();
      if (picked == null) return;
      setState(() {
        nameController.text = picked.displayName;
        if (picked.phones.isNotEmpty) pickedPhoneNumber = picked.phones.first.number;
      });
    } catch (error) {
      if (!dialogContext.mounted) return;
      ScaffoldMessenger.of(dialogContext)
          .showSnackBar(SnackBar(content: Text('تعذّر فتح جهات الاتصال: $error')));
    }
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('إعادة تسمية جهة الاتصال'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              onPressed: () => pickFromPhoneContacts(context, setState),
              icon: const Icon(Icons.contacts),
              label: const Text('اختيار من جهات الاتصال'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'الاسم المعروض'),
            ),
            if (pickedPhoneNumber != null) ...[
              const SizedBox(height: 8),
              Text('سيُحفَظ رقم الهاتف: $pickedPhoneNumber', style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
        ],
      ),
    ),
  );

  if (result != true || !context.mounted) return;
  final newName = nameController.text.trim();
  if (newName.isEmpty) return;

  await AppScope.of(context).renameContact(
    conversation.peerInternalNumber,
    newName,
    newPhoneNumber: pickedPhoneNumber,
  );
}
