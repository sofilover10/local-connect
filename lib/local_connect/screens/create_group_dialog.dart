import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/conversation.dart';
import 'chat_screen.dart';

/// ينشئ مجموعة أو قناة جديدة من جهات الاتصال المحفوظة أصلًا (لا يمكن دعوة
/// رقم لم يُضَف كجهة اتصال بعد — لا خادم مركزي يبحث عن أرقام عشوائية على
/// الشبكة). القناة تتطلب متابعًا واحدًا على الأقل ليصل لهم البث؛ يمكن
/// إضافة المزيد لاحقًا من شاشة معلومات القناة على أي حال.
///
/// [onCreated] اختياري: يُستدعى بالمحادثة المُنشأة حديثًا بدل الانتقال
/// التلقائي لشاشتها — تستخدمه شاشة تفاصيل مجتمع لإدراج المجموعة الجديدة
/// في المجتمع مباشرة (انظر AppState.addGroupToCommunity).
Future<void> showCreateGroupDialog(
  BuildContext context, {
  bool isChannel = false,
  void Function(Conversation)? onCreated,
}) async {
  final appState = AppScope.of(context);
  final nameController = TextEditingController();
  final selected = <String>{};
  final minMembers = isChannel ? 1 : 2;

  if (appState.contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('أضف جهات اتصال أولًا قبل إنشاء ${isChannel ? 'قناة' : 'مجموعة'}')),
    );
    return;
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(isChannel ? 'قناة جديدة' : 'مجموعة جديدة'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(labelText: isChannel ? 'اسم القناة' : 'اسم المجموعة'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text(isChannel ? 'اختر المتابعين الأوائل:' : 'اختر الأعضاء:'),
              ),
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
              onPressed: selected.length < minMembers || value.text.trim().isEmpty
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
    isChannel: isChannel,
  );

  if (onCreated != null) {
    onCreated(conversation);
    return;
  }
  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
}
