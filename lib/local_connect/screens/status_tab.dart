import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/status_post.dart';
import '../services/app_state.dart';
import 'status_viewer_screen.dart';

/// تبويب "الحالات" — منشورات مؤقتة (24 ساعة) لي ولجهات اتصالي، تُبَثّ عند
/// نشرها لكل جهة اتصال مباشرة (بلا خادم مركزي، انظر AppState.postStatus).
class StatusTab extends StatelessWidget {
  const StatusTab({super.key, required this.appState});

  final LocalConnectAppState appState;

  Future<void> _showPostMenu(BuildContext context) async {
    // context الخارجي (معطى هنا) مستقر طوال بقاء تبويب الحالات، خلافًا
    // لـcontext الداخلي لـbuilder المرتبط بعنصر القائمة السفلية نفسها —
    // ذاك يُلغى بمجرد انتهاء حركة إغلاقها، وهي أسرع بكثير من الوقت الذي
    // يستغرقه منتقي الملفات (المستخدم يتصفّح لثوانٍ)، فتفشل كل فحوصات
    // context.mounted اللاحقة بصمت. راجع نفس الشرح المُفصَّل في
    // ChatScreen._showAttachMenu.
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('حالة نصية'),
              onTap: () {
                Navigator.pop(sheetContext);
                _postTextStatus(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('صورة أو ملف'),
              onTap: () {
                Navigator.pop(sheetContext);
                _postFileStatus(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _postTextStatus(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حالة نصية'),
        content: TextField(controller: controller, autofocus: true, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('نشر')),
        ],
      ),
    );
    if (result != true || !context.mounted) return;
    final posted = await appState.postStatus(text: controller.text, kind: StatusKind.text);
    if (!posted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر نشر الحالة')),
      );
    }
  }

  Future<void> _postFileStatus(BuildContext context) async {
    // withData: true تحسّبًا لمصدر لا يُرجِع مسار ملف حقيقي (راجع نفس
    // المنطق والتعليق في ChatScreen._pickAndSendFile).
    final result = await FilePicker.platform.pickFiles(type: FileType.media, withData: true);
    if (!context.mounted || result == null) return;
    final picked = result.files.single;

    String? path = picked.path;
    if (path == null || !await File(path).exists()) {
      final bytes = picked.bytes;
      if (bytes == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر الوصول لهذا الملف — جرّب اختيار ملف من التخزين المحلي مباشرة')),
        );
        return;
      }
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}_${picked.name}');
      await tempFile.writeAsBytes(bytes);
      path = tempFile.path;
    }

    if (!context.mounted) return;
    final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.webp']
        .any((ext) => path!.toLowerCase().endsWith(ext));
    final posted =
        await appState.postStatus(filePath: path, kind: isImage ? StatusKind.image : StatusKind.file);
    if (!posted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر نشر الحالة — تحقق من شاشة "فحص الأخطاء" للتفاصيل')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final active = appState.activeStatuses;
        final myNumber = appState.identity.internalNumber;
        final myStatuses = active.where((s) => s.authorInternalNumber == myNumber).toList()
          ..sort((a, b) => b.postedAt.compareTo(a.postedAt));
        final othersStatuses = active.where((s) => s.authorInternalNumber != myNumber).toList();

        final byAuthor = <String, List<StatusPost>>{};
        for (final status in othersStatuses) {
          byAuthor.putIfAbsent(status.authorInternalNumber, () => []).add(status);
        }
        for (final list in byAuthor.values) {
          list.sort((a, b) => b.postedAt.compareTo(a.postedAt));
        }

        return ListView(
          children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.add)),
              title: const Text('إضافة حالة'),
              onTap: () => _showPostMenu(context),
            ),
            if (myStatuses.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('حالاتي', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final status in myStatuses)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.bar_chart)),
                  title: Text(status.text ?? status.attachmentFileName ?? 'حالة'),
                  subtitle: Text(
                    '${DateFormat.Hm().format(status.postedAt)} · ${status.viewedBy.length} مشاهدة',
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => StatusViewerScreen(statuses: [status])),
                  ),
                ),
            ],
            if (byAuthor.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('حالات جهات الاتصال', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final entry in byAuthor.entries)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(entry.value.first.authorDisplayName.isEmpty
                        ? '?'
                        : entry.value.first.authorDisplayName[0]),
                  ),
                  title: Text(entry.value.first.authorDisplayName),
                  subtitle: Text('${entry.value.length} حالة · ${DateFormat.Hm().format(entry.value.first.postedAt)}'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => StatusViewerScreen(statuses: entry.value)),
                  ),
                ),
            ],
            if (myStatuses.isEmpty && byAuthor.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('لا توجد حالات حاليًا.')),
              ),
          ],
        );
      },
    );
  }
}
