import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/conversation.dart';
import 'chat_screen.dart';

/// المحادثات المؤرشَفة محليًا فقط — الأرشفة قرار شخصي على كل جهاز، لا
/// تُرسَل للطرف الآخر ولا تُغيّر شيئًا لديه.
class ArchivedConversationsScreen extends StatelessWidget {
  const ArchivedConversationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('الأرشيف')),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final archived = appState.conversations.where((c) => c.isArchived).toList()
            ..sort((a, b) => (b.lastMessageAt ?? DateTime(0)).compareTo(a.lastMessageAt ?? DateTime(0)));

          if (archived.isEmpty) {
            return const Center(child: Text('لا توجد محادثات مؤرشَفة.'));
          }

          return ListView.builder(
            itemCount: archived.length,
            itemBuilder: (context, index) {
              final Conversation conversation = archived[index];
              return ListTile(
                leading: CircleAvatar(
                  child: Text(conversation.peerDisplayName.isEmpty ? '?' : conversation.peerDisplayName[0]),
                ),
                title: Text(conversation.peerDisplayName),
                subtitle: Text(
                  conversation.lastMessagePreview ?? conversation.peerInternalNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'إلغاء الأرشفة',
                  icon: const Icon(Icons.unarchive_outlined),
                  onPressed: () => appState.setConversationArchived(conversation.id, false),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
