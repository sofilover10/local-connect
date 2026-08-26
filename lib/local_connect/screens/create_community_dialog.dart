import 'package:flutter/material.dart';

import '../app_scope.dart';

/// ينشئ مجتمعًا جديدًا يجمع مجموعات/قنوات أملكها أصلًا تحت اسم واحد، مع
/// دعوة أعضاء له. لا يضمّ الانضمام للمجتمع أي عضو تلقائيًا لأي مجموعة
/// منضوية فيه — عضوية كل مجموعة تبقى مستقلة تمامًا (انظر AppState.createCommunity).
Future<void> showCreateCommunityDialog(BuildContext context) async {
  final appState = AppScope.of(context);
  final nameController = TextEditingController();
  final selectedMembers = <String>{};
  final selectedGroups = <String>{};

  final ownedGroups =
      appState.conversations.where((c) => c.isGroup && c.groupOwnerInternalNumber == appState.identity.internalNumber).toList();

  if (appState.contacts.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('أضف جهات اتصال أولًا قبل إنشاء مجتمع')));
    return;
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('مجتمع جديد'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'اسم المجتمع'),
                ),
                const SizedBox(height: 8),
                const Align(alignment: Alignment.centerRight, child: Text('اختر الأعضاء:')),
                ...appState.contacts.map((contact) {
                  final isSelected = selectedMembers.contains(contact.internalNumber);
                  return CheckboxListTile(
                    dense: true,
                    value: isSelected,
                    title: Text(contact.displayName),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selectedMembers.add(contact.internalNumber);
                      } else {
                        selectedMembers.remove(contact.internalNumber);
                      }
                    }),
                  );
                }),
                if (ownedGroups.isNotEmpty) ...[
                  const Divider(),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Text('اختر مجموعات/قنوات تملكها لإدراجها (اختياري):'),
                  ),
                  ...ownedGroups.map((group) {
                    final isSelected = selectedGroups.contains(group.id);
                    return CheckboxListTile(
                      dense: true,
                      value: isSelected,
                      title: Text(group.peerDisplayName),
                      subtitle: Text(group.isChannel ? 'قناة' : 'مجموعة'),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          selectedGroups.add(group.id);
                        } else {
                          selectedGroups.remove(group.id);
                        }
                      }),
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: nameController,
            builder: (context, value, _) => FilledButton(
              onPressed: selectedMembers.isEmpty || value.text.trim().isEmpty
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

  await appState.createCommunity(
    name: nameController.text.trim(),
    memberInternalNumbers: selectedMembers.toList(),
    linkedConversationIds: selectedGroups.toList(),
  );
}
