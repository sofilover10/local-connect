import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_scope.dart';
import '../models/call_session.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../widgets/message_bubble.dart';
import '../widgets/status_dot.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  Timer? _recordingTicker;
  Duration _recordingElapsed = Duration.zero;

  /// معرّف الرسالة قيد التعديل حاليًا، أو null إن كنا نكتب رسالة جديدة.
  String? _editingMessageId;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _recordingTicker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send(BuildContext context) {
    final text = _controller.text;
    if (text.trim().isEmpty) return;

    final editingId = _editingMessageId;
    if (editingId != null) {
      AppScope.of(context)
          .editMessage(conversationId: widget.conversation.id, messageId: editingId, newText: text);
      setState(() => _editingMessageId = null);
    } else {
      AppScope.of(context).sendMessage(conversationId: widget.conversation.id, text: text);
    }
    _controller.clear();
    _scrollToBottom();
  }

  void _startEdit(ChatMessage message) {
    setState(() {
      _editingMessageId = message.id;
      _controller.text = message.text;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingMessageId = null;
      _controller.clear();
    });
  }

  Future<void> _deleteForMe(BuildContext context, ChatMessage message) async {
    await AppScope.of(context)
        .deleteMessage(conversationId: widget.conversation.id, messageId: message.id, forEveryone: false);
  }

  Future<void> _deleteForEveryone(BuildContext context, ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف للجميع؟'),
        content: const Text('ستُحذَف هذه الرسالة لدى الطرف الآخر أيضًا إن كان بالإمكان الوصول إليه.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await AppScope.of(context)
        .deleteMessage(conversationId: widget.conversation.id, messageId: message.id, forEveryone: true);
  }

  Future<void> _pickAndSendFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null || !context.mounted) return;
    await AppScope.of(context).sendAttachment(
      conversationId: widget.conversation.id,
      filePath: path,
      kind: MessageKind.file,
    );
    _scrollToBottom();
  }

  Future<void> _toggleVoiceRecording(BuildContext context) async {
    if (_isRecording) {
      _recordingTicker?.cancel();
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _recordingElapsed = Duration.zero;
      });
      if (path == null || !context.mounted) return;
      await AppScope.of(context).sendAttachment(
        conversationId: widget.conversation.id,
        filePath: path,
        kind: MessageKind.voice,
        mimeType: 'audio/m4a',
      );
      _scrollToBottom();
      return;
    }

    if (!await _recorder.hasPermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('يحتاج تسجيل الصوت صلاحية الميكروفون')),
        );
      }
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    setState(() {
      _isRecording = true;
      _recordingElapsed = Duration.zero;
    });
    _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordingElapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _saveToPhoneContacts(BuildContext context) async {
    final appState = AppScope.of(context);
    final saved = await appState.saveContactToPhoneBook(widget.conversation.peerInternalNumber);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saved ? 'تم الحفظ في جهات اتصال الهاتف' : 'تعذّر الحفظ — تحقق من صلاحية جهات الاتصال'),
      ),
    );
  }

  Future<void> _startCall(BuildContext context, CallMediaType mediaType) async {
    final appState = AppScope.of(context);
    if (appState.callService.currentCall != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يوجد مكالمة جارية بالفعل')),
      );
      return;
    }
    await appState.callService.startCall(
      peerInternalNumber: widget.conversation.peerInternalNumber,
      peerDisplayName: widget.conversation.peerDisplayName,
      mediaType: mediaType,
    );
  }

  Future<void> _toggleArchive(BuildContext context) async {
    final newValue = !widget.conversation.isArchived;
    await AppScope.of(context).setConversationArchived(widget.conversation.id, newValue);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newValue ? 'أُرشِفَت المحادثة' : 'أُلغِيَت أرشفة المحادثة')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context);

    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final messages = appState.messagesFor(widget.conversation.id);
        final online = appState.isPeerOnline(widget.conversation.peerInternalNumber);

        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(online: online),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.conversation.peerDisplayName, overflow: TextOverflow.ellipsis),
                      Text(
                        online ? 'متصل الآن على الشبكة' : 'غير ظاهر حاليًا — سيتم الإرسال عند ظهوره',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.call),
                tooltip: 'اتصال صوتي',
                onPressed: () => _startCall(context, CallMediaType.audio),
              ),
              IconButton(
                icon: const Icon(Icons.videocam),
                tooltip: 'اتصال مرئي',
                onPressed: () => _startCall(context, CallMediaType.video),
              ),
              PopupMenuButton<void>(
                itemBuilder: (context) => [
                  PopupMenuItem(
                    onTap: () => _saveToPhoneContacts(context),
                    child: const Text('حفظ في جهات اتصال الهاتف'),
                  ),
                  PopupMenuItem(
                    onTap: () => _toggleArchive(context),
                    child: Text(widget.conversation.isArchived ? 'إلغاء أرشفة المحادثة' : 'أرشفة المحادثة'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: messages.isEmpty
                    ? const Center(child: Text('لا توجد رسائل بعد، ابدأ المحادثة'))
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          return MessageBubble(
                            message: message,
                            onEdit: message.outgoing && message.kind == MessageKind.text
                                ? () => _startEdit(message)
                                : null,
                            onDeleteForMe: () => _deleteForMe(context, message),
                            onDeleteForEveryone:
                                message.outgoing ? () => _deleteForEveryone(context, message) : null,
                          );
                        },
                      ),
              ),
              if (_isRecording)
                Container(
                  width: double.infinity,
                  color: Colors.red.shade50,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const _PulsingRecordingDot(),
                      const SizedBox(width: 10),
                      const Text(
                        'جارٍ تسجيل رسالة صوتية...',
                        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        _formatDuration(_recordingElapsed),
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              if (_editingMessageId != null)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.edit, size: 16),
                      const SizedBox(width: 6),
                      const Expanded(child: Text('تعديل رسالة', style: TextStyle(fontSize: 12))),
                      IconButton(
                        onPressed: _cancelEdit,
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed:
                            (_isRecording || _editingMessageId != null) ? null : () => _pickAndSendFile(context),
                        icon: const Icon(Icons.attach_file),
                        tooltip: 'إرسال ملف',
                      ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          enabled: !_isRecording,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(context),
                          decoration: InputDecoration(
                            hintText: _isRecording ? 'جارٍ تسجيل رسالة صوتية...' : 'اكتب رسالة...',
                            border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(Radius.circular(24))),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _editingMessageId != null ? null : () => _toggleVoiceRecording(context),
                        icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic),
                        color: _isRecording ? Colors.red : null,
                        tooltip: _isRecording ? 'إيقاف وإرسال الرسالة الصوتية' : 'تسجيل رسالة صوتية',
                      ),
                      IconButton.filled(
                        onPressed: _isRecording ? null : () => _send(context),
                        icon: Icon(_editingMessageId != null ? Icons.check : Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// نقطة حمراء تنبض بصريًا (تكبر وتصغر) طوال مدة التسجيل — إشارة يصعب
/// تفويتها بخلاف مجرّد تغيير لون أيقونة صغيرة.
class _PulsingRecordingDot extends StatefulWidget {
  const _PulsingRecordingDot();

  @override
  State<_PulsingRecordingDot> createState() => _PulsingRecordingDotState();
}

class _PulsingRecordingDotState extends State<_PulsingRecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_controller),
      child: const Icon(Icons.circle, color: Colors.red, size: 12),
    );
  }
}
