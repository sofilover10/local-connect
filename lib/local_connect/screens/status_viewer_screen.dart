import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_scope.dart';
import '../models/status_post.dart';

/// يعرض حالات مُرسِل واحد بالتتابع (أقدَمها أولًا، كأي "قصة")، ويُبلِغ
/// AppState بمشاهدة كل حالة فور ظهورها على الشاشة.
class StatusViewerScreen extends StatefulWidget {
  const StatusViewerScreen({super.key, required this.statuses});

  final List<StatusPost> statuses;

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen> {
  late final List<StatusPost> _ordered =
      widget.statuses.toList()..sort((a, b) => a.postedAt.compareTo(b.postedAt));
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _markViewed(0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _markViewed(int index) {
    if (!mounted) return;
    AppScope.of(context).markStatusViewed(_ordered[index].id);
  }

  Future<void> _showViewers(BuildContext context) async {
    final appState = AppScope.of(context);
    final status = _ordered[_index];
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: status.viewedBy.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد مشاهدات بعد.'))
            : ListView(
                shrinkWrap: true,
                children: status.viewedBy.map((internalNumber) {
                  final matches = appState.contacts.where((c) => c.internalNumber == internalNumber);
                  final name = matches.isEmpty ? internalNumber : matches.first.displayName;
                  return ListTile(leading: const Icon(Icons.visibility), title: Text(name));
                }).toList(),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);
    final myNumber = appState.identity.internalNumber;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_ordered.first.authorDisplayName),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _ordered.length,
        onPageChanged: (index) {
          setState(() => _index = index);
          _markViewed(index);
        },
        itemBuilder: (context, index) {
          final status = _ordered[index];
          return Column(
            children: [
              Row(
                children: List.generate(
                  _ordered.length,
                  (i) => Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                      color: i <= index ? Colors.white : Colors.white24,
                    ),
                  ),
                ),
              ),
              Expanded(child: _StatusContent(status: status)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  DateFormat.yMd().add_Hm().format(status.postedAt),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              if (status.authorInternalNumber == myNumber)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextButton.icon(
                    onPressed: () => _showViewers(context),
                    icon: const Icon(Icons.visibility, color: Colors.white70),
                    label: Text(
                      '${status.viewedBy.length} مشاهدة',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusContent extends StatelessWidget {
  const _StatusContent({required this.status});

  final StatusPost status;

  @override
  Widget build(BuildContext context) {
    switch (status.kind) {
      case StatusKind.text:
        return Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
          child: Text(
            status.text ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
          ),
        );
      case StatusKind.image:
        if (status.attachmentLocalPath == null) {
          return const Center(
            child: Text('جارٍ استلام الصورة...', style: TextStyle(color: Colors.white54)),
          );
        }
        return InteractiveViewer(
          child: Center(child: Image.file(File(status.attachmentLocalPath!))),
        );
      case StatusKind.file:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, color: Colors.white, size: 48),
              const SizedBox(height: 12),
              Text(
                status.attachmentFileName ?? 'ملف',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
    }
  }
}
