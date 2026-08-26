import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/community.dart';
import '../models/conversation.dart';
import 'chat_screen.dart';
import 'create_community_dialog.dart';

class CommunitiesScreen extends StatelessWidget {
  const CommunitiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('المجتمعات')),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          if (appState.communities.isEmpty) {
            return const Center(child: Text('لا توجد مجتمعات بعد.'));
          }
          return ListView.builder(
            itemCount: appState.communities.length,
            itemBuilder: (context, index) {
              final community = appState.communities[index];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.diversity_3)),
                title: Text(community.name),
                subtitle: Text(
                  '${community.memberInternalNumbers.length + 1} أعضاء · ${community.linkedConversationIds.length} مجموعة/قناة',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => CommunityDetailScreen(community: community)),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showCreateCommunityDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class CommunityDetailScreen extends StatelessWidget {
  const CommunityDetailScreen({super.key, required this.community});

  final Community community;

  Future<void> _leave(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مغادرة المجتمع؟'),
        content: Text(
          'لن تبقى عضوًا في مجتمع "${community.name}" بعد المغادرة (لا يؤثر هذا على عضويتك في أي مجموعة داخله).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('مغادرة')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await AppScope.of(context).leaveCommunity(community.id);
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final stillExists = appState.communities.any((c) => c.id == community.id);
        if (!stillExists) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.canPop(context)) Navigator.pop(context);
          });
          return const SizedBox.shrink();
        }

        final linkedGroups = <Conversation>[];
        for (final id in community.linkedConversationIds) {
          final matches = appState.conversations.where((c) => c.id == id);
          if (matches.isNotEmpty) linkedGroups.add(matches.first);
        }

        return Scaffold(
          appBar: AppBar(title: Text(community.name)),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const CircleAvatar(radius: 36, child: Icon(Icons.diversity_3, size: 36)),
                    const SizedBox(height: 8),
                    Text(community.name, style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      '${community.memberInternalNumbers.length + 1} أعضاء',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('المجموعات والقنوات', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (linkedGroups.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text('لا توجد مجموعات مُدرَجة، أو لستَ عضوًا في أي منها.'),
                )
              else
                for (final group in linkedGroups)
                  ListTile(
                    leading: Icon(group.isChannel ? Icons.campaign : Icons.groups),
                    title: Text(group.peerDisplayName),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ChatScreen(conversation: group)),
                    ),
                  ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text('مغادرة المجتمع', style: TextStyle(color: Colors.red)),
                onTap: () => _leave(context),
              ),
            ],
          ),
        );
      },
    );
  }
}
