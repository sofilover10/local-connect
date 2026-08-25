import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

/// عرض مرفق ملف عادي (غير صوتي) داخل فقاعة المحادثة: اسم الملف وحجمه،
/// وفتحه بتطبيق النظام المناسب عند الضغط.
class FileMessageTile extends StatelessWidget {
  const FileMessageTile({
    super.key,
    required this.fileName,
    required this.sizeBytes,
    required this.filePath,
    required this.color,
  });

  final String fileName;
  final int? sizeBytes;
  final String? filePath;
  final Color color;

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: filePath == null ? null : () => OpenFilex.open(filePath!),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, color: color, size: 28),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fileName, style: TextStyle(color: color), overflow: TextOverflow.ellipsis),
                if (sizeBytes != null)
                  Text(
                    _formatSize(sizeBytes!),
                    style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
