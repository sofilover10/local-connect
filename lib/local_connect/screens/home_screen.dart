import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../models/peer_info.dart';
import '../services/app_state.dart';
import '../widgets/status_dot.dart';
import 'add_contact_dialog.dart';
import 'archived_conversations_screen.dart';
import 'blocked_contacts_screen.dart';
import 'bluetooth_tab.dart';
import 'chat_screen.dart';
import 'create_group_dialog.dart';
import 'diagnostics_screen.dart';
import 'edit_name_dialog.dart';
import 'wifi_direct_tab.dart';

Future<void> _showAddMenu(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('إضافة جهة اتصال'),
            onTap: () {
              Navigator.pop(context);
              showAddContactDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.group_add),
            title: const Text('مجموعة جديدة'),
            onTap: () {
              Navigator.pop(context);
              showCreateGroupDialog(context);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _showAbout(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('LocalConnect 🇵🇸'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // شريط بألوان علم فلسطين — هوية بصرية بسيطة بلا حاجة لملف صورة.
          // إطار خفيف حتى يظهر الشريط الأبيض على خلفية الحوار البيضاء.
          Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)),
            child: const Row(
              children: [
                _FlagStripe(color: Colors.black),
                _FlagStripe(color: Colors.white),
                _FlagStripe(color: Colors.green),
                _FlagStripe(color: Colors.red),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('الإصدار ${info.version} (رقم البناء ${info.buildNumber})'),
          const SizedBox(height: 16),
          const Text('برمجة وتصميم وتطوير:'),
          const Text('م. عبدالله حميد الصوفي', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('صُنع من أجل فلسطين 🇵🇸', style: TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    ),
  );
}

class _FlagStripe extends StatelessWidget {
  const _FlagStripe({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 6,
        color: color,
        margin: const EdgeInsets.only(left: 2),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);
    // Activity متصلة فعليًا هنا (خلافًا لحظة init() المبكرة عند بدء
    // العملية)، فحوار صلاحية الإشعار قابل للعرض فعليًا الآن.
    unawaited(appState.ensureNotificationPermission());

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: AnimatedBuilder(
            animation: appState,
            builder: (context, _) => InkWell(
              onTap: () => showEditProfileDialog(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(appState.identity.displayName),
                  Text(
                    'رقمك الداخلي: ${appState.identity.internalNumber}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'عن التطبيق',
              onPressed: () => _showAbout(context),
              icon: const Icon(Icons.info_outline),
            ),
            IconButton(
              tooltip: 'الأرشيف',
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchivedConversationsScreen())),
              icon: const Icon(Icons.archive_outlined),
            ),
            IconButton(
              tooltip: 'المحظورون',
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const BlockedContactsScreen())),
              icon: const Icon(Icons.block),
            ),
            AnimatedBuilder(
              animation: appState,
              builder: (context, _) {
                final hasIssue = !appState.socket.isActive ||
                    !appState.discovery.isActive ||
                    appState.errorLog.isNotEmpty;
                return IconButton(
                  tooltip: 'فحص الأخطاء والاتصال',
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
                  icon: Icon(
                    hasIssue ? Icons.warning_amber_rounded : Icons.wifi_tethering,
                    color: hasIssue ? Colors.amber : null,
                  ),
                );
              },
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'المحادثات'),
              Tab(text: 'أجهزة قريبة (Wi-Fi)'),
              Tab(text: 'بلوتوث'),
              Tab(text: 'Wi-Fi Direct'),
            ],
          ),
        ),
        body: AnimatedBuilder(
          animation: appState,
          builder: (context, _) => Column(
            children: [
              if (appState.availableUpdate != null) _UpdateBanner(appState: appState),
              Expanded(
                child: TabBarView(
                  children: [
                    _ConversationsTab(appState: appState),
                    _NearbyDevicesTab(appState: appState),
                    BluetoothTab(appState: appState),
                    WifiDirectTab(appState: appState),
                  ],
                ),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showAddMenu(context),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class _ConversationsTab extends StatelessWidget {
  const _ConversationsTab({required this.appState});

  final LocalConnectAppState appState;

  @override
  Widget build(BuildContext context) {
    final conversations = appState.conversations.where((c) => !c.isArchived).toList()
      ..sort((a, b) {
        final aTime = a.lastMessageAt;
        final bTime = b.lastMessageAt;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

    if (conversations.isEmpty) {
      return const Center(child: Text('لا توجد محادثات بعد.\nأضف جهة اتصال أو اختر جهازًا قريبًا.', textAlign: TextAlign.center));
    }

    return ListView.builder(
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        final online = !conversation.isGroup && appState.isPeerOnline(conversation.peerInternalNumber);
        final initial =
            conversation.peerDisplayName.isEmpty ? '?' : conversation.peerDisplayName[0];
        return ListTile(
          leading: CircleAvatar(
            child: conversation.isGroup ? const Icon(Icons.groups) : Text(initial),
          ),
          title: Text(conversation.peerDisplayName),
          subtitle: Text(
            conversation.lastMessagePreview ??
                (conversation.isGroup ? 'مجموعة' : conversation.peerInternalNumber),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusDot(online: online),
              if (conversation.lastMessageAt != null)
                Text(
                  DateFormat.Hm().format(conversation.lastMessageAt!),
                  style: const TextStyle(fontSize: 11),
                ),
            ],
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
          ),
        );
      },
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.appState});

  final LocalConnectAppState appState;

  @override
  Widget build(BuildContext context) {
    final update = appState.availableUpdate!;
    return Container(
      width: double.infinity,
      color: Colors.teal.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(
            child: Text('يتوفر إصدار جديد (${update.versionTag})', style: const TextStyle(color: Colors.teal)),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse(update.downloadUrl), mode: LaunchMode.externalApplication),
            child: const Text('تحميل'),
          ),
        ],
      ),
    );
  }
}

class _NearbyDevicesTab extends StatelessWidget {
  const _NearbyDevicesTab({required this.appState});

  final LocalConnectAppState appState;

  @override
  Widget build(BuildContext context) {
    final peers = List<PeerInfo>.from(appState.nearbyDevices);

    if (peers.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد أجهزة أخرى ظاهرة حاليًا على الشبكة.\nتأكد أن الجهاز الآخر شغّال ومتصل بنفس الشبكة.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: peers.length,
      itemBuilder: (context, index) {
        final peer = peers[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.wifi_tethering)),
          title: Text(peer.displayName),
          subtitle: Text(peer.internalNumber),
          trailing: const StatusDot(online: true),
          onTap: () async {
            final conversation = await appState.addContactFromPeer(peer);
            if (!context.mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
            );
          },
        );
      },
    );
  }
}
