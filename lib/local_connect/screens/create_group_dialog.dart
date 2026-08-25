import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'chat_screen.dart';

/// ينشئ مجموعة جديدة من جهات الاتصال المحفوظة أصلًا (لا يمكن دعوة رقم لم
/// يُضَف كجهة اتصال بعد — لا خادم مركزي يبحث عن أرقام عشوائية على الشبكة).
Future<void> showCreateGroupDialog(BuildContext context) async {
  final appState = AppScope.of(context);
  final nameController = TextEditingController();
  final selected = <String>{};

  if (appState.contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('أضف جهات اتصال أولًا قبل إنشاء مجموعة')),
    );
    return;
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('مجموعة جديدة'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'اسم المجموعة'),
              ),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerRight, child: Text('اختر الأعضاء:')),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: appState.contacts.map((contact) {
                    final isSelected = selected.contains(contact.internalNumber);
                    return CheckboxListTile(
                      value: isSelected,
                      title: Text(contact.displayName),
                      subtitle: Text(contact.internalNumber),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          selected.add(contact.internalNumber);
                        } else {
                          selected.remove(contact.internalNumber);
                        }
                      }),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: nameController,
            builder: (context, value, _) => FilledButton(
              onPressed: selected.length < 2 || value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('إنشاء'),
            ),
          ),
        ],
      ),
    ),
  );

  if (result != true || !context.mounted) return;

  final conversation = await appState.createGroup(
    name: nameController.text.trim(),
    memberInternalNumbers: selected.toList(),
  );

  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
}
