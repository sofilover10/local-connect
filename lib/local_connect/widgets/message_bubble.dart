import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/message.dart';
import 'file_message_tile.dart';
import 'voice_message_player.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor =
        message.outgoing ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final textColor = message.outgoing ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Align(
      alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildContent(textColor),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.Hm().format(message.sentAt),
                  style: TextStyle(fontSize: 11, color: textColor.withValues(alpha: 0.7)),
                ),
                if (message.outgoing) ...[
                  const SizedBox(width: 4),
                  Icon(_statusIcon(message.status), size: 14, color: textColor.withValues(alpha: 0.8)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(Color textColor) {
    switch (message.kind) {
      case MessageKind.text:
        return Text(message.text, style: TextStyle(color: textColor));
      case MessageKind.voice:
        return message.attachmentLocalPath == null
            ? Text('رسالة صوتية (قيد الاستلام...)', style: TextStyle(color: textColor))
            : VoiceMessagePlayer(filePath: message.attachmentLocalPath!, iconColor: textColor);
      case MessageKind.file:
        return FileMessageTile(
          fileName: message.attachmentFileName ?? message.text,
          sizeBytes: message.attachmentSizeBytes,
          filePath: message.attachmentLocalPath,
          color: textColor,
        );
    }
  }

  IconData _statusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.queued:
        return Icons.schedule;
      case MessageStatus.sent:
      case MessageStatus.delivered:
        return Icons.done_all;
      case MessageStatus.failed:
        return Icons.error_outline;
    }
  }
}
