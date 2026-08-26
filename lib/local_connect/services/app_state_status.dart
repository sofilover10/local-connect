part of 'app_state.dart';

/// الحالات (منشورات مؤقتة تختفي بعد 24 ساعة) — انظر [StatusPost.lifetime].
extension StatusExtension on LocalConnectAppState {
  /// ينشر حالة جديدة (نص أو مرفق) ويبثّها لكل جهات الاتصال مباشرة — لا
  /// خادم مركزي يحتفظ بها؛ كل جهاز يحمل نسخته الخاصة من كل حالة وصلته.
  Future<void> postStatus({String? text, String? filePath, StatusKind kind = StatusKind.text}) async {
    final trimmedText = text?.trim();
    if (kind == StatusKind.text && (trimmedText == null || trimmedText.isEmpty)) return;
    if (contacts.isEmpty) return;

    String? attachmentFileName;
    String? base64Data;
    if (kind != StatusKind.text) {
      if (filePath == null || !await File(filePath).exists()) {
        recordError('نشر حالة', 'الملف غير موجود: $filePath');
        return;
      }
      attachmentFileName = filePath.split(Platform.pathSeparator).last;
      base64Data = base64Encode(await File(filePath).readAsBytes());
    }

    final status = StatusPost(
      id: const Uuid().v4(),
      authorInternalNumber: identity.internalNumber,
      authorDisplayName: identity.displayName,
      postedAt: DateTime.now(),
      text: trimmedText,
      kind: kind,
      attachmentFileName: attachmentFileName,
      attachmentLocalPath: filePath,
    );

    statuses.add(status);
    await _store.statusBox.put(status.id, _store.encode(status.toMap()));
    _safeNotify();

    final payload = <String, dynamic>{
      'type': 'status_post',
      'id': status.id,
      'senderInternalNumber': identity.internalNumber,
      'authorDisplayName': identity.displayName,
      'postedAt': status.postedAt.toIso8601String(),
      'kind': kind.name,
      if (trimmedText != null) 'text': trimmedText,
      if (attachmentFileName != null) 'attachmentFileName': attachmentFileName,
      if (base64Data != null) 'data': base64Data,
    };
    for (final contact in contacts) {
      unawaited(_deliverViaAnyTransport(contact.internalNumber, payload));
    }
  }

  void _handleIncomingStatusPost(String senderInternalNumber, Map<String, dynamic> payload) {
    final id = payload['id'];
    if (id is! String) return;
    if (statuses.any((s) => s.id == id)) return; // تفادي التكرار (وصلت عبر أكثر من وسيلة نقل)

    final kind = StatusKind.values.byName((payload['kind'] as String?) ?? 'text');
    final authorDisplayName = payload['authorDisplayName'] as String? ?? senderInternalNumber;
    final postedAt = DateTime.tryParse(payload['postedAt'] as String? ?? '') ?? DateTime.now();
    final base64Data = payload['data'] as String?;

    final status = StatusPost(
      id: id,
      authorInternalNumber: senderInternalNumber,
      authorDisplayName: authorDisplayName,
      postedAt: postedAt,
      text: payload['text'] as String?,
      kind: kind,
      attachmentFileName: payload['attachmentFileName'] as String?,
      attachmentMimeType: payload['attachmentMimeType'] as String?,
    );
    statuses.add(status);
    _safeNotify();

    unawaited(_store.statusBox.put(status.id, _store.encode(status.toMap())).then((_) async {
      if (kind != StatusKind.text && base64Data != null) {
        try {
          status.attachmentLocalPath = await _saveIncomingAttachment(
            conversationId: 'status',
            messageId: status.id,
            fileName: status.attachmentFileName ?? status.id,
            base64Data: base64Data,
          );
          await _store.statusBox.put(status.id, _store.encode(status.toMap()));
          _safeNotify();
        } catch (error) {
          recordError('حفظ مرفق حالة', error);
        }
      }
    }));
  }

  /// يُبلِغ صاحب الحالة أنني شاهدتها — لا يُرسَل شيء لحالتي أنا، ولا لحالة
  /// شاهدتُها فعلًا من قبل.
  Future<void> markStatusViewed(String statusId) async {
    final matches = statuses.where((s) => s.id == statusId);
    if (matches.isEmpty) return;
    final status = matches.first;
    if (status.authorInternalNumber == identity.internalNumber) return;
    if (status.viewedBy.contains(identity.internalNumber)) return;

    unawaited(_deliverViaAnyTransport(status.authorInternalNumber, {
      'type': 'status_view',
      'id': statusId,
      'senderInternalNumber': identity.internalNumber,
    }));
  }

  void _handleIncomingStatusView(String viewerInternalNumber, Map<String, dynamic> payload) {
    final id = payload['id'];
    if (id is! String) return;
    final matches =
        statuses.where((s) => s.id == id && s.authorInternalNumber == identity.internalNumber);
    if (matches.isEmpty) return;

    final status = matches.first;
    if (status.viewedBy.contains(viewerInternalNumber)) return;
    status.viewedBy.add(viewerInternalNumber);
    unawaited(_store.statusBox.put(status.id, _store.encode(status.toMap())));
    _safeNotify();
  }
}
