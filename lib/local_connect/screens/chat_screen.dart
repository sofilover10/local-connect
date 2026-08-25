import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_scope.dart';
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

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _recorder.dispose();
    super.dispose();
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
    AppScope.of(context).sendMessage(conversationId: widget.conversation.id, text: text);
    _controller.clear();
    _scrollToBottom();
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
      final path = await _recorder.stop();
      setState(() => _isRecording = false);
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
    setState(() => _isRecording = true);
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
              PopupMenuButton<void>(
                itemBuilder: (context) => [
                  PopupMenuItem(
                    onTap: () => _saveToPhoneContacts(context),
                    child: const Text('حفظ في جهات اتصال الهاتف'),
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
                        itemBuilder: (context, index) => MessageBubble(message: messages[index]),
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _isRecording ? null : () => _pickAndSendFile(context),
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
                        onPressed: () => _toggleVoiceRecording(context),
                        icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic),
                        color: _isRecording ? Colors.red : null,
                        tooltip: _isRecording ? 'إيقاف وإرسال الرسالة الصوتية' : 'تسجيل رسالة صوتية',
                      ),
                      IconButton.filled(
                        onPressed: _isRecording ? null : () => _send(context),
                        icon: const Icon(Icons.send),
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
