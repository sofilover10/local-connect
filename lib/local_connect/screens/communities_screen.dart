import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/community.dart';
import '../models/conversation.dart';
import 'chat_screen.dart';
import 'create_community_dialog.dart';
import 'create_group_dialog.dart';

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

  Future<void> _leave(BuildContext context, Community liveCommunity, bool isOwner) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('مغادرة المجتمع؟'),
        content: Text(
          isOwner
              ? 'أنت مالك مجتمع "${liveCommunity.name}" — لا يوجد نقل ملكية تلقائي في هذه النسخة. '
                  'بعد مغادرتك، يبقى المجتمع كما هو لدى بقية الأعضاء، لكن لن يقدر أحد إضافة مجموعات '
                  'جديدة إليه بعد الآن. لا يؤثر هذا على عضويتك في أي مجموعة داخله.'
              : 'لن تبقى عضوًا في مجتمع "${liveCommunity.name}" بعد المغادرة (لا يؤثر هذا على عضويتك في أي مجموعة داخله).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('مغادرة')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await AppScope.of(context).leaveCommunity(liveCommunity.id);
    if (!context.mounted) return;
    // لا حاجة لاستدعاء Navigator.pop يدويًا هنا — إزالة المجتمع محليًا (أعلاه)
    // يجعل stillExists أدناه false في إعادة البناء التالية، فيُغلِق الشاشة
    // نفسه تلقائيًا؛ استدعاء pop هنا مباشرة كان يُغلِقها قبل أن يتسنّى لهذا
    // التنبيه الظهور فعليًا.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('غادرتَ مجتمع "${liveCommunity.name}"')),
    );
  }

  /// المجتمع بلا أي مجموعة مُدرَجة حاوية فارغة بلا مكان للدردشة إطلاقًا —
  /// هذا هو المسار الوحيد لإضافة مكان دردشة له بعد إنشائه (الإدراج عند
  /// الإنشاء نفسه اختياري ويقتصر على المجموعات المملوكة وقتها فقط).
  Future<void> _showAddGroupMenu(
    BuildContext context,
    LocalConnectAppState appState,
    Community liveCommunity,
  ) async {
    final ownedUnlinked = appState.conversations
        .where((c) =>
            c.isGroup &&
            c.groupOwnerInternalNumber == appState.identity.internalNumber &&
            !liveCommunity.linkedConversationIds.contains(c.id))
        .toList();

    // context الخارجي (معطى هنا) مستقر طوال بقاء هذه الشاشة، خلافًا
    // لـcontext الداخلي لـbuilder المرتبط بعنصر القائمة السفلية نفسها —
    // ذاك يُلغى بمجرد انتهاء حركة إغلاقها، وهي أقصر بكثير من وقت ملء
    // حوار إنشاء مجموعة، فتفشل عملية الإنشاء/الإدراج بصمت.
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add),
              title: const Text('إنشاء مجموعة جديدة وإدراجها'),
              onTap: () {
                Navigator.pop(sheetContext);
                showCreateGroupDialog(
                  context,
                  onCreated: (conversation) =>
                      AppScope.of(context).addGroupToCommunity(liveCommunity.id, conversation.id),
                );
              },
            ),
            if (ownedUnlinked.isNotEmpty) ...[
              const Divider(height: 1),
              for (final group in ownedUnlinked)
                ListTile(
                  leading: Icon(group.isChannel ? Icons.campaign : Icons.groups),
                  title: Text(group.peerDisplayName),
                  subtitle: const Text('إدراج مجموعة تملكها أصلًا'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    appState.addGroupToCommunity(liveCommunity.id, group.id);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        // يُقرَأ الكائن الحيّ الحالي من appState دائمًا بدل الاعتماد على
        // المرجع الملتقَط عند فتح الشاشة (community أعلاه) — إن وصل تحديث
        // (مثلًا community_invite مُعاد بعد إضافة مجموعة أو عضو) بعد فتح هذه
        // الشاشة، يجب أن تعكس الشاشة القيم الحالية فورًا، لا نسخة قديمة
        // عالقة وقت الفتح. هذا هو سبب تضارب عدد الأعضاء المُبلَّغ عنه بين
        // بطاقة القائمة ورأس هذه الشاشة سابقًا.
        final matches = appState.communities.where((c) => c.id == community.id);
        if (matches.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.canPop(context)) Navigator.pop(context);
          });
          return const SizedBox.shrink();
        }
        final liveCommunity = matches.first;
        final isOwner = liveCommunity.ownerInternalNumber == appState.identity.internalNumber;

        final linkedGroups = <Conversation>[];
        for (final id in liveCommunity.linkedConversationIds) {
          final groupMatches = appState.conversations.where((c) => c.id == id);
          if (groupMatches.isNotEmpty) linkedGroups.add(groupMatches.first);
        }

        return Scaffold(
          appBar: AppBar(title: Text(liveCommunity.name)),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const CircleAvatar(radius: 36, child: Icon(Icons.diversity_3, size: 36)),
                    const SizedBox(height: 8),
                    Text(liveCommunity.name, style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      '${liveCommunity.memberInternalNumbers.length + 1} أعضاء',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('المجموعات والقنوات', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    if (isOwner)
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        tooltip: 'إضافة مجموعة',
                        onPressed: () => _showAddGroupMenu(context, appState, liveCommunity),
                      ),
                  ],
                ),
              ),
              if (linkedGroups.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    isOwner
                        ? 'لا توجد مجموعات مُدرَجة بعد — اضغط + لإضافة أو إنشاء واحدة، فيصبح لها مكان للدردشة.'
                        : 'لا توجد مجموعات مُدرَجة، أو لستَ عضوًا في أي منها.',
                  ),
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
                onTap: () => _leave(context, liveCommunity, isOwner),
              ),
            ],
          ),
        );
      },
    );
  }
}
