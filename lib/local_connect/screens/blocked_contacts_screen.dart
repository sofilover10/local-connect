import 'package:flutter/material.dart';

import '../app_scope.dart';

/// قائمة الأرقام المحظورة — الحظر يمنع أي رسالة أو إشارة مكالمة واردة من
/// هذا الرقم في [LocalConnectAppState._handleIncomingWire]، ويمنعك أنت من
/// إرسال رسالة أو بدء مكالمة له أيضًا حتى تُلغي الحظر من هنا.
class BlockedContactsScreen extends StatelessWidget {
  const BlockedContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('المحظورون')),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final blocked = appState.blockedInternalNumbers.toList()..sort();

          if (blocked.isEmpty) {
            return const Center(child: Text('لا يوجد أي رقم محظور حاليًا.'));
          }

          return ListView.builder(
            itemCount: blocked.length,
            itemBuilder: (context, index) {
              final internalNumber = blocked[index];
              final contactMatches = appState.contacts.where((c) => c.internalNumber == internalNumber);
              final displayName = contactMatches.isEmpty ? internalNumber : contactMatches.first.displayName;

              return ListTile(
                leading: CircleAvatar(child: Text(displayName.isEmpty ? '?' : displayName[0])),
                title: Text(displayName),
                subtitle: Text(internalNumber),
                trailing: TextButton(
                  onPressed: () => appState.unblockContact(internalNumber),
                  child: const Text('إلغاء الحظر'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
