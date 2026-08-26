import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/conversation.dart';

/// معلومات المجموعة وإدارة أعضائها. إضافة/إزالة عضو تقتصر على مالك
/// المجموعة (منشئها) في هذه النسخة — لا صلاحيات إدارية متدرّجة بعد. أي
/// عضو (بما فيه المالك) يقدر يغادر بنفسه من هنا.
class GroupInfoScreen extends StatelessWidget {
  const GroupInfoScreen({super.key, required this.conversation});

  final Conversation conversation;

  Future<void> _leaveGroup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مغادرة المجموعة؟'),
        content: Text('لن تصلك رسائل ${conversation.peerDisplayName} بعد المغادرة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('مغادرة')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await AppScope.of(context).leaveGroup(conversation.id);
    if (!context.mounted) return;
    Navigator.of(context)
      ..pop() // GroupInfoScreen
      ..pop(); // ChatScreen — المجموعة لم تعد موجودة لدينا بعد المغادرة
  }

  Future<void> _addMember(BuildContext context) async {
    final appState = AppScope.of(context);
    final candidates = appState.contacts
        .where((c) => !conversation.memberInternalNumbers.contains(c.internalNumber))
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('كل جهات اتصالك أعضاء في المجموعة أصلًا')));
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('إضافة عضو'),
        children: candidates
            .map((c) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, c.internalNumber),
                  child: Text(c.displayName),
                ))
            .toList(),
      ),
    );
    if (selected == null) return;
    await appState.addGroupMember(conversation.id, selected);
  }

  Future<void> _removeMember(BuildContext context, String memberInternalNumber, String memberName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إزالة عضو؟'),
        content: Text('ستُزال $memberName من المجموعة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إزالة')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await AppScope.of(context).removeGroupMember(conversation.id, memberInternalNumber);
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        // المحادثة قد تُحذَف محليًا (طُردنا، أو غادر أحدهم من جهاز آخر)
        // أثناء عرض هذه الشاشة بالذات.
        final stillExists = appState.conversations.any((c) => c.id == conversation.id);
        if (!stillExists) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.canPop(context)) Navigator.pop(context);
          });
          return const SizedBox.shrink();
        }

        final isOwner = conversation.groupOwnerInternalNumber == appState.identity.internalNumber;
        final members = [
          (appState.identity.internalNumber, appState.identity.displayName, true),
          ...conversation.memberInternalNumbers.map((internalNumber) {
            final matches = appState.contacts.where((c) => c.internalNumber == internalNumber);
            final name = matches.isEmpty ? internalNumber : matches.first.displayName;
            return (internalNumber, name, internalNumber == conversation.groupOwnerInternalNumber);
          }),
        ];

        return Scaffold(
          appBar: AppBar(title: const Text('معلومات المجموعة')),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const CircleAvatar(radius: 36, child: Icon(Icons.groups, size: 36)),
                    const SizedBox(height: 8),
                    Text(conversation.peerDisplayName, style: Theme.of(context).textTheme.titleLarge),
                    Text('${members.length} أعضاء', style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
              const Divider(),
              if (isOwner)
                ListTile(
                  leading: const Icon(Icons.person_add),
                  title: const Text('إضافة عضو'),
                  onTap: () => _addMember(context),
                ),
              ...members.map((entry) {
                final (internalNumber, name, isMemberOwner) = entry;
                final isSelf = internalNumber == appState.identity.internalNumber;
                return ListTile(
                  leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name[0])),
                  title: Text(isSelf ? '$name (أنت)' : name),
                  subtitle: isMemberOwner ? const Text('المالك') : null,
                  trailing: (isOwner && !isSelf)
                      ? IconButton(
                          icon: const Icon(Icons.person_remove, color: Colors.red),
                          tooltip: 'إزالة من المجموعة',
                          onPressed: () => _removeMember(context, internalNumber, name),
                        )
                      : null,
                );
              }),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text('مغادرة المجموعة', style: TextStyle(color: Colors.red)),
                onTap: () => _leaveGroup(context),
              ),
            ],
          ),
        );
      },
    );
  }
}
