part of 'app_state.dart';

/// إرسال الرسائل (نص/مرفق/استطلاع)، التسليم متعدد وسائل النقل، وتعديل/حذف
/// الرسائل وأرشفة المحادثات.
extension MessagingExtension on LocalConnectAppState {
  Future<void> sendMessage({required String conversationId, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isConversationBlocked(conversationId) || !_canPostToConversation(conversationId)) {
      return;
    }

    final message = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderInternalNumber: identity.internalNumber,
      text: trimmed,
      sentAt: DateTime.now(),
      outgoing: true,
    );

    _messagesByConversation.putIfAbsent(conversationId, () => []).add(message);
    await _persistMessage(message);
    _updateConversationPreview(conversationId, message);
    _safeNotify();

    await _attemptDelivery(message);
  }

  /// إرسال ملف (أي نوع) أو رسالة صوتية موجودة مسبقًا كملف على القرص —
  /// [filePath] هو مسار الملف الأصلي (من منتقي الملفات أو من مسجّل الصوت).
  /// يعيد true إن أُنشئت الرسالة فعليًا (بصرف النظر عن نجاح التسليم لاحقًا،
  /// الذي يُعاد المحاولة فيه تلقائيًا)، أو false إن رُفض الملف نفسه فورًا —
  /// حتى تقدر الشاشة تعرض تنبيهًا واضحًا للمستخدم بدل فشل صامت تمامًا.
  Future<bool> sendAttachment({
    required String conversationId,
    required String filePath,
    required MessageKind kind,
    String? mimeType,
    String? caption,
  }) async {
    if (_isConversationBlocked(conversationId) || !_canPostToConversation(conversationId)) return false;
    final file = File(filePath);
    if (!await file.exists()) {
      recordError('إرسال مرفق', 'الملف غير موجود أو غير قابل للقراءة: $filePath');
      return false;
    }
    final fileName = filePath.split(Platform.pathSeparator).last;
    final sizeBytes = await file.length();

    final message = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderInternalNumber: identity.internalNumber,
      text: caption ?? fileName,
      sentAt: DateTime.now(),
      outgoing: true,
      kind: kind,
      attachmentFileName: fileName,
      attachmentMimeType: mimeType,
      attachmentSizeBytes: sizeBytes,
      attachmentLocalPath: filePath,
    );

    _messagesByConversation.putIfAbsent(conversationId, () => []).add(message);
    await _persistMessage(message);
    _updateConversationPreview(
      conversationId,
      message,
      previewOverride: kind == MessageKind.voice ? '🎤 رسالة صوتية' : '📎 $fileName',
    );
    _safeNotify();

    await _attemptDelivery(message);
    return true;
  }

  /// ينشئ استطلاعًا برأي واحد لكل شخص (لا خيارات متعددة في هذه النسخة).
  Future<void> sendPoll({
    required String conversationId,
    required String question,
    required List<String> options,
  }) async {
    final trimmedQuestion = question.trim();
    final trimmedOptions = options.map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
    if (trimmedQuestion.isEmpty ||
        trimmedOptions.length < 2 ||
        _isConversationBlocked(conversationId) ||
        !_canPostToConversation(conversationId)) {
      return;
    }

    final message = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderInternalNumber: identity.internalNumber,
      text: trimmedQuestion,
      sentAt: DateTime.now(),
      outgoing: true,
      kind: MessageKind.poll,
      pollOptions: trimmedOptions,
    );

    _messagesByConversation.putIfAbsent(conversationId, () => []).add(message);
    await _persistMessage(message);
    _updateConversationPreview(conversationId, message, previewOverride: '📊 $trimmedQuestion');
    _safeNotify();

    await _attemptDelivery(message);
  }

  /// يصوّت (أو يغيّر صوته) في استطلاع — صوت واحد فقط لكل شخص، فيُزال أي
  /// صوت سابق له من كل الخيارات الأخرى أولًا. يُحدَّث النسخة المحلية فورًا
  /// (بمن فيهم صاحب الاستطلاع نفسه)، ثم يُرسَل التحديث الكامل لبقية
  /// الأطراف حتى تُطابق نتائجهم لديهم — وليس فرق التصويت فقط، تفاديًا لأي
  /// تعارض لو صوّت أكثر من شخص في نفس اللحظة تقريبًا.
  Future<void> voteInPoll({
    required String conversationId,
    required String messageId,
    required int optionIndex,
  }) async {
    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];
    if (message.kind != MessageKind.poll || message.pollOptions == null) return;
    if (optionIndex < 0 || optionIndex >= message.pollOptions!.length) return;

    final votes = message.pollVotes ?? {};
    for (final voters in votes.values) {
      voters.remove(identity.internalNumber);
    }
    votes.putIfAbsent('$optionIndex', () => []).add(identity.internalNumber);
    message.pollVotes = votes;
    await _persistMessage(message);
    _safeNotify();

    final conversation = conversations.firstWhere((c) => c.id == conversationId);
    final votePayload = {
      'type': 'poll_vote',
      'id': message.id,
      'senderInternalNumber': identity.internalNumber,
      'pollVotes': votes,
    };
    unawaited(conversation.isGroup
        ? _fanOutToGroup(conversation, votePayload)
        : _deliverViaAnyTransport(conversation.peerInternalNumber, votePayload));
  }

  void _handleIncomingPollVote(String conversationId, Map<String, dynamic> payload) {
    final id = payload['id'];
    final pollVotesRaw = payload['pollVotes'];
    if (id is! String || pollVotesRaw is! Map) return;

    final list = _messagesByConversation[conversationId];
    final messageIndex = list?.indexWhere((m) => m.id == id) ?? -1;
    if (list == null || messageIndex == -1) return;

    final message = list[messageIndex];
    if (message.kind != MessageKind.poll) return;

    message.pollVotes = pollVotesRaw.map(
      (key, value) => MapEntry(key as String, (value as List<dynamic>).cast<String>()),
    );
    unawaited(_persistMessage(message));
    _safeNotify();
  }

  /// ينشئ فعالية (اجتماع/موعد) في محادثة — [text] يحمل عنوانها.
  Future<void> sendEvent({
    required String conversationId,
    required String title,
    required DateTime dateTime,
    String? location,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty ||
        _isConversationBlocked(conversationId) ||
        !_canPostToConversation(conversationId)) {
      return;
    }
    final trimmedLocation = location?.trim();

    final message = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderInternalNumber: identity.internalNumber,
      text: trimmedTitle,
      sentAt: DateTime.now(),
      outgoing: true,
      kind: MessageKind.event,
      eventDateTime: dateTime,
      eventLocation: (trimmedLocation == null || trimmedLocation.isEmpty) ? null : trimmedLocation,
    );

    _messagesByConversation.putIfAbsent(conversationId, () => []).add(message);
    await _persistMessage(message);
    _updateConversationPreview(conversationId, message, previewOverride: '📅 $trimmedTitle');
    _safeNotify();

    await _attemptDelivery(message);
  }

  /// يردّ (أو يغيّر رده) على دعوة فعالية — رد واحد فقط لكل شخص، يُحدَّث
  /// محليًا فورًا ثم يُرسَل التحديث الكامل لبقية الأطراف، بنفس منطق
  /// [voteInPoll] وللسبب نفسه: تفادي تعارض ردود متزامنة تقريبًا.
  Future<void> respondToEvent({
    required String conversationId,
    required String messageId,
    required EventRsvpStatus status,
  }) async {
    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];
    if (message.kind != MessageKind.event) return;

    final rsvps = message.eventRsvps ?? {};
    rsvps[identity.internalNumber] = status.name;
    message.eventRsvps = rsvps;
    await _persistMessage(message);
    _safeNotify();

    final conversation = conversations.firstWhere((c) => c.id == conversationId);
    final rsvpPayload = {
      'type': 'event_rsvp',
      'id': message.id,
      'senderInternalNumber': identity.internalNumber,
      'eventRsvps': rsvps,
    };
    unawaited(conversation.isGroup
        ? _fanOutToGroup(conversation, rsvpPayload)
        : _deliverViaAnyTransport(conversation.peerInternalNumber, rsvpPayload));
  }

  void _handleIncomingEventRsvp(String conversationId, Map<String, dynamic> payload) {
    final id = payload['id'];
    final rsvpsRaw = payload['eventRsvps'];
    if (id is! String || rsvpsRaw is! Map) return;

    final list = _messagesByConversation[conversationId];
    final messageIndex = list?.indexWhere((m) => m.id == id) ?? -1;
    if (list == null || messageIndex == -1) return;

    final message = list[messageIndex];
    if (message.kind != MessageKind.event) return;

    message.eventRsvps = rsvpsRaw.map((key, value) => MapEntry(key as String, value as String));
    unawaited(_persistMessage(message));
    _safeNotify();
  }

  Future<void> _attemptDelivery(ChatMessage message) async {
    final conversation = conversations.firstWhere((c) => c.id == message.conversationId);

    String? base64Data;
    // فقط الصوت/الملف يحملان بايتات مرفق فعلية على القرص — النص والاستطلاع
    // كلاهما "غير نص عادي" بمعنى kind، لكن لا مرفق لأي منهما إطلاقًا.
    if (message.kind == MessageKind.voice || message.kind == MessageKind.file) {
      final path = message.attachmentLocalPath;
      if (path == null || !await File(path).exists()) {
        message.status = MessageStatus.failed;
        await _persistMessage(message);
        _safeNotify();
        return;
      }
      base64Data = base64Encode(await File(path).readAsBytes());
    }

    final payload = message.toWirePayload(base64Data: base64Data);
    message.status = conversation.isGroup
        ? await _fanOutToGroup(conversation, payload)
        : await _deliverViaAnyTransport(conversation.peerInternalNumber, payload);
    await _persistMessage(message);
    _safeNotify();
  }

  /// يُرسِل نفس الحمولة لكل عضو في مجموعة على حدة (توزيع نجمي بسيط: كل
  /// جهاز يبعث لكل الأعضاء الآخرين مباشرة بلا خادم وسيط) — يُلحق [Conversation.id]
  /// كـgroupId لأن الطرف المستقبِل لا يقدر يشتقّه محليًا كحال المحادثات
  /// الثنائية (لا يوجد "طرفان" فقط لاشتقاق معرّف حتمي منهما).
  /// delivered فقط إن وصلت للجميع؛ غير ذلك queued لإعادة المحاولة — تكرار
  /// الإرسال لعضو استلمها فعلًا بالفعل غير ضار لأن جانب الاستقبال يتجاهل
  /// أي معرّف رسالة مكرَّر.
  Future<MessageStatus> _fanOutToGroup(Conversation group, Map<String, dynamic> payload) async {
    if (group.memberInternalNumbers.isEmpty) return MessageStatus.delivered;
    final groupPayload = {...payload, 'groupId': group.id};
    var allDelivered = true;
    for (final member in group.memberInternalNumbers) {
      final status = await _deliverViaAnyTransport(member, groupPayload);
      if (status != MessageStatus.delivered && status != MessageStatus.sent) {
        allDelivered = false;
      }
    }
    return allDelivered ? MessageStatus.delivered : MessageStatus.queued;
  }

  /// يجرّب كل وسيلة اتصال متاحة بالترتيب حتى تنجح واحدة: Wi-Fi المكتشَف
  /// تلقائيًا، ثم عنوان IP يدوي (Wi-Fi أيضًا)، ثم بلوتوث كلاسيكي — الثلاثة
  /// الأولى تُقِرّ باستلام الطرف الآخر فعليًا (delivered)، فتعمل حتى لو لم
  /// يظهر عبر اكتشاف UDP إطلاقًا (مثلًا بسبب عزل أجهزة على الراوتر).
  /// المُرحِّل المركزي هو المحاولة الأخيرة فقط (يحتاج إنترنت على الجهازين)؛
  /// نجاحه يعني فقط أن الخادم استلم الرسالة وسيسلّمها لاحقًا، وليس أن
  /// الطرف الآخر استلمها فعليًا الآن — لذا يُعلَّم sent لا delivered. يبقى
  /// queued تلقائيًا إن فشلت كل الوسائل، لإعادة المحاولة لاحقًا.
  ///
  /// يأخذ الرقم الداخلي مباشرة (لا كائن Conversation) حتى تقدر إشارات
  /// المكالمات (WebRTC signaling) تعيد استخدامه أيضًا دون الحاجة لمحادثة
  /// نصية قائمة أصلًا.
  Future<MessageStatus> _deliverViaAnyTransport(
    String peerInternalNumber,
    Map<String, dynamic> payload,
  ) async {
    final timeout = _deliveryTimeoutFor(payload);
    final peer = discovery.peerByInternalNumber(peerInternalNumber);
    if (peer != null) {
      final delivered = await socket.sendDirect(
        address: peer.address,
        port: peer.tcpPort,
        payload: payload,
        timeout: timeout,
      );
      if (delivered) return MessageStatus.delivered;
    }

    final matches = contacts.where((c) => c.internalNumber == peerInternalNumber);
    final contact = matches.isEmpty ? null : matches.first;

    final manualAddress = contact?.manualAddress;
    if (manualAddress != null) {
      final parsed = InternetAddress.tryParse(manualAddress);
      if (parsed != null) {
        final delivered = await socket.sendDirect(
          address: parsed,
          port: socket.preferredPort,
          payload: payload,
          timeout: timeout,
        );
        if (delivered) return MessageStatus.delivered;
      }
    }

    final bluetoothAddress = contact?.bluetoothAddress;
    if (bluetoothAddress != null) {
      final delivered =
          await bluetoothMessaging.sendDirect(address: bluetoothAddress, payload: payload, timeout: timeout);
      if (delivered) return MessageStatus.delivered;
    }

    final sentViaRelay = await relay.send(to: peerInternalNumber, payload: payload);
    if (sentViaRelay) return MessageStatus.sent;

    return MessageStatus.failed;
  }

  /// المهلة الافتراضية (3 ثوانٍ في MessagingSocketService.sendDirect) كافية
  /// لرسالة نصية عادية، لكنها قصيرة جدًا لمرفق كبير: الاتصال + كتابة كل
  /// البايتات + انتظار الطرف الآخر يُحلِّل JSON بحجم ميغابايتات ويُقِرّ
  /// الاستلام قد يتجاوز 3 ثوانٍ بسهولة حتى على شبكة محلية جيدة، فتفشل
  /// الرسالة بصمت رغم وصولها فعليًا (كان هذا السبب الفعلي وراء عدم وصول
  /// ملفات كبيرة مثل APK رغم رفع حد الذاكرة في MessagingSocketService).
  /// نفترض معدل نقل متحفظ 2 ميغابايت/ثانية (يشمل بلوتوث الأبطأ) زائد 5
  /// ثوانٍ ثابتة للاتصال والمعالجة.
  Duration _deliveryTimeoutFor(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is! String || data.length < 200 * 1024) return const Duration(seconds: 3);
    final estimatedSeconds = 5 + (data.length / (2 * 1024 * 1024)).ceil();
    return Duration(seconds: estimatedSeconds.clamp(3, 180));
  }

  /// يُستخدَم من [CallService] لإرسال إشارات WebRTC (عروض/ردود/مرشّحات ICE)
  /// عبر نفس سلسلة النقل الاحتياطية المستخدمة للرسائل العادية.
  Future<bool> sendCallSignal(String peerInternalNumber, Map<String, dynamic> payload) async {
    final status = await _deliverViaAnyTransport(peerInternalNumber, payload);
    return status == MessageStatus.delivered || status == MessageStatus.sent;
  }

  Future<void> _retryQueuedMessages() async {
    for (final entry in _messagesByConversation.entries) {
      for (final message in entry.value) {
        if (message.outgoing &&
            (message.status == MessageStatus.queued || message.status == MessageStatus.failed)) {
          await _attemptDelivery(message);
        }
      }
    }
  }

  /// يعدّل نص رسالة نصية صادرة أرسلتَها أنت بنفسك. يُحدَّث النسخة المحلية
  /// فورًا، ويُرسَل تعديل للطرف الآخر كمحاولة واحدة أفضل-جهد (بلا قائمة
  /// انتظار دائمة كالرسائل نفسها) — إن كان غير ظاهر الآن، سيبقى نصه
  /// القديم لديه إلى أن تُرسِل له رسالة أخرى تنجح لاحقًا.
  Future<void> editMessage({
    required String conversationId,
    required String messageId,
    required String newText,
  }) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;

    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];
    if (!message.outgoing || message.kind != MessageKind.text) return;

    message.text = trimmed;
    message.editedAt = DateTime.now();
    await _persistMessage(message);
    _updateConversationPreview(conversationId, message);
    _safeNotify();

    final conversation = conversations.firstWhere((c) => c.id == conversationId);
    final editPayload = {
      'type': 'edit_message',
      'id': message.id,
      'senderInternalNumber': identity.internalNumber,
      'text': trimmed,
      'editedAt': message.editedAt!.toIso8601String(),
    };
    unawaited(conversation.isGroup
        ? _fanOutToGroup(conversation, editPayload)
        : _deliverViaAnyTransport(conversation.peerInternalNumber, editPayload));
  }

  /// حذف "لي فقط": يُزيل الرسالة محليًا نهائيًا بلا أي إخطار للطرف الآخر.
  /// حذف "للجميع": يُبقيها عنصرًا نائبًا فارغًا محليًا (بنفس أسلوب واتساب)،
  /// ويُرسِل طلب حذف للطرف الآخر — لا يجوز إلا على رسالة أرسلتَها أنت.
  Future<void> deleteMessage({
    required String conversationId,
    required String messageId,
    required bool forEveryone,
  }) async {
    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];

    if (forEveryone) {
      if (!message.outgoing) return;
      message.isDeleted = true;
      await _persistMessage(message);
      final conversation = conversations.firstWhere((c) => c.id == conversationId);
      final deletePayload = {
        'type': 'delete_message',
        'id': message.id,
        'senderInternalNumber': identity.internalNumber,
      };
      unawaited(conversation.isGroup
          ? _fanOutToGroup(conversation, deletePayload)
          : _deliverViaAnyTransport(conversation.peerInternalNumber, deletePayload));
    } else {
      list.removeAt(index);
      final box = await _store.messagesBoxFor(conversationId);
      await box.delete(messageId);
    }
    _safeNotify();
  }

  /// الأرشفة محلية بحتة — لا تُرسَل للطرف الآخر ولا تؤثر على محادثته هو.
  Future<void> setConversationArchived(String conversationId, bool archived) async {
    final conversation = conversations.firstWhere((c) => c.id == conversationId);
    conversation.isArchived = archived;
    await _store.conversationsBox.put(conversationId, _store.encode(conversation.toMap()));
    _safeNotify();
  }
}
