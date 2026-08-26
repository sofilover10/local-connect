import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/message.dart';
import 'file_message_tile.dart';
import 'voice_message_player.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onEdit,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.senderLabel,
    this.myInternalNumber,
    this.onVote,
    this.onRsvp,
  });

  final ChatMessage message;
  final VoidCallback? onEdit;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;

  /// اسم مُرسِل الرسالة — يُعرَض فقط لرسالة واردة في محادثة جماعية (حيث قد
  /// يكون المُرسِل أي عضو، بخلاف المحادثة الثنائية حيث الطرف واحد معروف
  /// أصلًا من عنوان الشاشة).
  final String? senderLabel;

  /// رقمي الداخلي — لازم فقط لرسائل الاستطلاع، لتمييز خياري الحالي عن
  /// خيارات بقية المصوِّتين.
  final String? myInternalNumber;

  /// يُستدعى عند الضغط على خيار في استطلاع (فهرس الخيار). null لرسالة غير
  /// استطلاع.
  final void Function(int optionIndex)? onVote;

  /// يُستدعى عند الرد على دعوة فعالية. null لرسالة غير فعالية.
  final void Function(EventRsvpStatus status)? onRsvp;

  bool get _hasActions => onEdit != null || onDeleteForMe != null || onDeleteForEveryone != null;

  Future<void> _showActions(BuildContext context) async {
    final canEdit = onEdit != null && message.outgoing && message.kind == MessageKind.text;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('تعديل'),
                onTap: () {
                  Navigator.pop(context);
                  onEdit!();
                },
              ),
            if (onDeleteForMe != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('حذف لديّ'),
                onTap: () {
                  Navigator.pop(context);
                  onDeleteForMe!();
                },
              ),
            if (onDeleteForEveryone != null && message.outgoing)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('حذف للجميع', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onDeleteForEveryone!();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor =
        message.outgoing ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final textColor = message.outgoing ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Align(
      alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: (_hasActions && !message.isDeleted) ? () => _showActions(context) : null,
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
              if (senderLabel != null && !message.outgoing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    senderLabel!,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor.withValues(alpha: 0.85)),
                  ),
                ),
              _buildContent(textColor),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.editedAt != null && !message.isDeleted) ...[
                    Text(
                      'تم التعديل · ',
                      style: TextStyle(fontSize: 11, color: textColor.withValues(alpha: 0.7)),
                    ),
                  ],
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
      ),
    );
  }

  Widget _buildContent(Color textColor) {
    if (message.isDeleted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 16, color: textColor.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Text(
            'تم حذف هذه الرسالة',
            style: TextStyle(color: textColor.withValues(alpha: 0.7), fontStyle: FontStyle.italic),
          ),
        ],
      );
    }

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
      case MessageKind.poll:
        return _PollContent(
          message: message,
          textColor: textColor,
          myInternalNumber: myInternalNumber,
          onVote: onVote,
        );
      case MessageKind.event:
        return _EventContent(
          message: message,
          textColor: textColor,
          myInternalNumber: myInternalNumber,
          onRsvp: onRsvp,
        );
    }
  }

  IconData _statusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.queued:
        return Icons.schedule;
      case MessageStatus.sent:
        // وصلت للمُرحِّل المركزي فقط، لم يستلمها الطرف الآخر فعليًا بعد —
        // صح واحدة (بخلاف صحّين لـdelivered) تُميّز هذا الفرق للمستخدم.
        return Icons.done;
      case MessageStatus.delivered:
        return Icons.done_all;
      case MessageStatus.failed:
        return Icons.error_outline;
    }
  }
}

class _PollContent extends StatelessWidget {
  const _PollContent({
    required this.message,
    required this.textColor,
    required this.myInternalNumber,
    required this.onVote,
  });

  final ChatMessage message;
  final Color textColor;
  final String? myInternalNumber;
  final void Function(int optionIndex)? onVote;

  @override
  Widget build(BuildContext context) {
    final options = message.pollOptions ?? const [];
    final votes = message.pollVotes ?? const {};
    final totalVotes = votes.values.fold<int>(0, (sum, voters) => sum + voters.length);
    var myVoteIndex = -1;
    if (myInternalNumber != null) {
      for (final entry in votes.entries) {
        if (entry.value.contains(myInternalNumber)) {
          myVoteIndex = int.tryParse(entry.key) ?? -1;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.bar_chart, size: 16, color: textColor.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message.text,
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < options.length; i++) ...[
          _PollOptionRow(
            label: options[i],
            voteCount: votes['$i']?.length ?? 0,
            totalVotes: totalVotes,
            selected: myVoteIndex == i,
            textColor: textColor,
            onTap: onVote == null ? null : () => onVote!(i),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          totalVotes == 0 ? 'لا يوجد تصويت بعد' : '$totalVotes صوت',
          style: TextStyle(fontSize: 11, color: textColor.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  const _PollOptionRow({
    required this.label,
    required this.voteCount,
    required this.totalVotes,
    required this.selected,
    required this.textColor,
    this.onTap,
  });

  final String label;
  final int voteCount;
  final int totalVotes;
  final bool selected;
  final Color textColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ratio = totalVotes == 0 ? 0.0 : voteCount / totalVotes;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio,
              child: Container(
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: textColor.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  size: 16,
                  color: selected ? textColor : textColor.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: TextStyle(color: textColor))),
                Text('$voteCount', style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EventContent extends StatelessWidget {
  const _EventContent({
    required this.message,
    required this.textColor,
    required this.myInternalNumber,
    required this.onRsvp,
  });

  final ChatMessage message;
  final Color textColor;
  final String? myInternalNumber;
  final void Function(EventRsvpStatus status)? onRsvp;

  static const _labels = {
    EventRsvpStatus.going: 'سأحضر',
    EventRsvpStatus.maybe: 'ربما',
    EventRsvpStatus.declined: 'لن أحضر',
  };

  @override
  Widget build(BuildContext context) {
    final rsvps = message.eventRsvps ?? const {};
    final myStatusName = myInternalNumber == null ? null : rsvps[myInternalNumber];
    final myStatus = EventRsvpStatus.values.where((s) => s.name == myStatusName);
    final goingCount = rsvps.values.where((v) => v == EventRsvpStatus.going.name).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.event, size: 16, color: textColor.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message.text,
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        if (message.eventDateTime != null) ...[
          const SizedBox(height: 4),
          Text(
            DateFormat('EEEE، d MMMM y — HH:mm', 'ar').format(message.eventDateTime!),
            style: TextStyle(color: textColor.withValues(alpha: 0.85), fontSize: 12),
          ),
        ],
        if (message.eventLocation != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.place_outlined, size: 14, color: textColor.withValues(alpha: 0.7)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  message.eventLocation!,
                  style: TextStyle(color: textColor.withValues(alpha: 0.85), fontSize: 12),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (onRsvp != null)
          Wrap(
            spacing: 6,
            children: [
              for (final status in EventRsvpStatus.values)
                ChoiceChip(
                  label: Text(_labels[status]!),
                  selected: myStatus.isNotEmpty && myStatus.first == status,
                  onSelected: (_) => onRsvp!(status),
                ),
            ],
          ),
        const SizedBox(height: 4),
        Text(
          goingCount == 0 ? 'لا أحد أكّد الحضور بعد' : '$goingCount سيحضرون',
          style: TextStyle(fontSize: 11, color: textColor.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}
