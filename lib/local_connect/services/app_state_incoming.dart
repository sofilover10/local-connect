part of 'app_state.dart';

/// معالجة الحمولات الواردة من كل وسائل النقل (Wi-Fi/بلوتوث/المُرحِّل) —
/// نقطة الدخول الموحَّدة [_handleIncomingWire] وكل ما تُوجِّه إليه.
extension IncomingWireExtension on LocalConnectAppState {
  /// أي جهاز على الشبكة المحلية يمكنه فتح اتصال TCP وإرسال JSON تعسفي، لذا
  /// يجب عدم الوثوق ببنية الحمولة الواردة؛ حزمة مشوَّهة يجب أن تُهمَل
  /// وتُسجَّل في سجل الأخطاء بدل أن تُسقِط معالجة الرسائل بالكامل.
  void _handleIncomingWire(Map<String, dynamic> payload) {
    try {
      final senderInternalNumber = payload['senderInternalNumber'];
      if (senderInternalNumber is! String || !_isSafeIdentifier(senderInternalNumber)) {
        // senderInternalNumber يُستخدم لاحقًا لبناء معرّف المحادثة، الذي
        // يُستخدم بدوره كاسم صندوق تخزين (Hive) واسم مجلد مرفقات على
        // القرص — رفض أي قيمة تحتوي أحرفًا خارج نطاق آمن (بدل محاولة
        // "تنظيفها") يمنع أي محاولة اجتياز مسار (path traversal) من جهاز
        // آخر على الشبكة منذ البداية.
        recordError('رسالة واردة', 'حمولة غير صالحة من الشبكة تم تجاهلها');
        return;
      }

      // نقطة تنفيذ الحظر الوحيدة: تُسقِط أي شيء من رقم محظور بصمت تام قبل
      // معالجته — رسائل نصية، تعديل/حذف، وإشارات مكالمات (call_offer...)
      // كلها تمر من هنا، فحظر شخص يمنعه من مراسلتك **و** الاتصال بك معًا.
      if (blockedInternalNumbers.contains(senderInternalNumber)) return;

      final type = payload['type'];

      if (type == 'group_invite') {
        _handleGroupInvite(senderInternalNumber, payload);
        return;
      }
      if (type == 'group_member_update') {
        _handleGroupMemberUpdate(payload);
        return;
      }
      if (type == 'community_invite') {
        _handleIncomingCommunityInvite(senderInternalNumber, payload);
        return;
      }
      if (type == 'community_member_update') {
        _handleIncomingCommunityMemberUpdate(payload);
        return;
      }
      if (type == 'community_group_added') {
        _handleIncomingCommunityGroupAdded(payload);
        return;
      }

      // معرّف المحادثة: لرسائل مجموعة، المُرسِل يحدّده صراحة (groupId) لأنه
      // لا يمكن اشتقاقه محليًا كحال المحادثات الثنائية (لا يوجد "طرفان" فقط
      // لحسابه منهما حتميًا) — نتحقق أننا عضو فعلي في تلك المجموعة محليًا
      // (وصلتنا دعوتها) قبل قبول أي شيء يشير إليها، وإلا فأي جهاز على
      // الشبكة كان يقدر "يخترع" عضويتنا في مجموعة بمجرّد ادّعاء groupId.
      // لغير ذلك، يُحسَب معرّف المحادثة محليًا دائمًا من رقمَي الطرفين، ولا
      // يُوثَق بالقيمة التي قد يُرسِلها الطرف الآخر ضمن الحمولة نفسها.
      String conversationId;
      final groupId = payload['groupId'];
      if (groupId is String && _isSafeIdentifier(groupId)) {
        final groupMatches = conversations.where((c) => c.id == groupId && c.isGroup);
        if (groupMatches.isEmpty) return;
        conversationId = groupId;
      } else {
        conversationId = Conversation.idFor(identity.internalNumber, senderInternalNumber);
      }

      switch (type) {
        case 'edit_message':
          _handleIncomingEdit(conversationId, senderInternalNumber, payload);
          return;
        case 'delete_message':
          _handleIncomingDelete(conversationId, senderInternalNumber, payload);
          return;
        case 'poll_vote':
          _handleIncomingPollVote(conversationId, payload);
          return;
        case 'event_rsvp':
          _handleIncomingEventRsvp(conversationId, payload);
          return;
        case 'status_post':
          _handleIncomingStatusPost(senderInternalNumber, payload);
          return;
        case 'status_view':
          _handleIncomingStatusView(senderInternalNumber, payload);
          return;
        case 'call_offer':
        case 'call_answer':
        case 'call_ice_candidate':
        case 'call_reject':
        case 'call_end':
          // إشارات المكالمات لا تُخزَّن كرسائل محادثة — تُمرَّر مباشرة إلى
          // خدمة المكالمات المناسبة. وجود groupId يميّز إشارة اتصال WebRTC
          // مباشر بين عضوين ضمن مكالمة جماعية عن مكالمة ثنائية عادية.
          if (groupId is String) {
            unawaited(groupCallService.handleSignal(payload));
          } else {
            unawaited(callService.handleSignal(payload));
          }
          return;
        case 'group_call_invite':
        case 'group_call_join':
        case 'group_call_roster':
          unawaited(groupCallService.handleSignal(payload));
          return;
        default:
          _handleIncomingNewMessage(conversationId, senderInternalNumber, payload);
      }
    } catch (error) {
      recordError('معالجة رسالة واردة', error);
    }
  }

  void _handleIncomingNewMessage(
    String conversationId,
    String senderInternalNumber,
    Map<String, dynamic> payload,
  ) {
    final id = payload['id'];
    final text = payload['text'];
    if (id is! String || text is! String) {
      recordError('رسالة واردة', 'حمولة غير صالحة من الشبكة تم تجاهلها');
      return;
    }

    final kind = MessageKind.values.byName((payload['kind'] as String?) ?? 'text');
    final base64Data = payload['data'] as String?;

    final message = ChatMessage(
      id: id,
      conversationId: conversationId,
      senderInternalNumber: senderInternalNumber,
      text: text,
      sentAt: DateTime.tryParse(payload['sentAt'] as String? ?? '') ?? DateTime.now(),
      status: MessageStatus.delivered,
      outgoing: false,
      kind: kind,
      attachmentFileName: payload['attachmentFileName'] as String?,
      attachmentMimeType: payload['attachmentMimeType'] as String?,
      attachmentSizeBytes: payload['attachmentSizeBytes'] as int?,
      pollOptions: (payload['pollOptions'] as List<dynamic>?)?.cast<String>(),
      pollVotes: (payload['pollVotes'] as Map<String, dynamic>?)
          ?.map((key, value) => MapEntry(key, (value as List<dynamic>).cast<String>())),
      eventDateTime: payload['eventDateTime'] == null
          ? null
          : DateTime.tryParse(payload['eventDateTime'] as String),
      eventLocation: payload['eventLocation'] as String?,
      eventRsvps: (payload['eventRsvps'] as Map<String, dynamic>?)?.cast<String, String>(),
    );

    _handleValidIncomingMessage(conversationId, senderInternalNumber, message, base64Data);
  }

  /// يتحقق أن senderInternalNumber المرافق لطلب التعديل يطابق ما هو مخزَّن
  /// فعليًا مع الرسالة الأصلية، فيمنع على الأقل حالة عدم الاتساق (تعديل/حذف
  /// حمولة تشير خطأً أو عمدًا لرسالة ذات مُرسِل مختلف). هذا **ليس** إثباتًا
  /// حقيقيًا للهوية: البروتوكول كله لا يحتوي أي تحقق تشفيري يربط اتصال TCP
  /// بجهاز بعينه، فأي جهاز على الشبكة يقدر أصلًا يدّعي senderInternalNumber
  /// أي رقم يريده (بما فيها الرقم الصحيح نفسه) — تمامًا كحال الرسائل العادية.
  /// هذا التطبيق مصمَّم أصلًا كشبكة ثقة محلية (LAN)، وليس مقاومًا لأطراف
  /// خبيثة فعليًا؛ تحقق هوية حقيقي يحتاج بنية تشفيرية (مفتاح لكل جهاز
  /// وتوقيع الرسائل) خارج نطاق هذه النسخة.
  void _handleIncomingEdit(
    String conversationId,
    String senderInternalNumber,
    Map<String, dynamic> payload,
  ) {
    final id = payload['id'];
    final newText = payload['text'];
    if (id is! String || newText is! String) return;

    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == id) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];
    if (message.senderInternalNumber != senderInternalNumber) {
      recordError('تعديل رسالة واردة', 'محاولة تعديل رسالة من مرسِل مختلف، تم تجاهلها');
      return;
    }

    message.text = newText;
    message.editedAt = DateTime.tryParse(payload['editedAt'] as String? ?? '') ?? DateTime.now();
    unawaited(_persistMessage(message));
    _safeNotify();
  }

  void _handleIncomingDelete(
    String conversationId,
    String senderInternalNumber,
    Map<String, dynamic> payload,
  ) {
    final id = payload['id'];
    if (id is! String) return;

    final list = _messagesByConversation[conversationId];
    final index = list?.indexWhere((m) => m.id == id) ?? -1;
    if (list == null || index == -1) return;

    final message = list[index];
    if (message.senderInternalNumber != senderInternalNumber) {
      recordError('حذف رسالة واردة', 'محاولة حذف رسالة من مرسِل مختلف، تم تجاهلها');
      return;
    }

    message.isDeleted = true;
    unawaited(_persistMessage(message));
    _safeNotify();
  }

  void _handleValidIncomingMessage(
    String conversationId,
    String senderInternalNumber,
    ChatMessage message,
    String? base64Data,
  ) {
    // لرسالة مجموعة، المحادثة (بمعرّف groupId) موجودة أصلًا بالضرورة — تحقّق
    // ذلك جرى في _handleIncomingWire قبل الوصول هنا. استدعاء _ensureConversation
    // في هذه الحالة كان سيُنشئ محادثة ثنائية زائفة مع المُرسِل (عضو المجموعة)
    // خطأً، منفصلة تمامًا عن محادثة المجموعة الفعلية.
    final isKnownGroup = conversations.any((c) => c.id == conversationId && c.isGroup);

    // قناة بث: لا يجوز قبول رسالة إلا من مالكها — وإلا لأمكن لأي متابع
    // (أو جهاز يدّعي رقمًا داخليًا) حقن منشورات مزيَّفة تبدو رسمية للجميع.
    final channelMatches = conversations.where((c) => c.id == conversationId && c.isChannel);
    if (channelMatches.isNotEmpty && channelMatches.first.groupOwnerInternalNumber != senderInternalNumber) {
      recordError('رسالة قناة واردة', 'رسالة من غير مالك القناة تم تجاهلها');
      return;
    }

    final ensureFuture = isKnownGroup
        ? Future<Conversation?>.value()
        : _ensureConversation(internalNumber: senderInternalNumber, displayName: senderInternalNumber);

    unawaited(ensureFuture.then((_) async {
      final list = _messagesByConversation.putIfAbsent(conversationId, () => []);
      if (list.any((m) => m.id == message.id)) return; // تفادي التكرار

      if (message.kind != MessageKind.text && base64Data != null) {
        try {
          message.attachmentLocalPath = await _saveIncomingAttachment(
            conversationId: conversationId,
            messageId: message.id,
            fileName: message.attachmentFileName ?? message.id,
            base64Data: base64Data,
          );
        } catch (error) {
          recordError('حفظ مرفق وارد', error);
        }
      }

      list.add(message);
      await _persistMessage(message);
      final preview = message.kind == MessageKind.voice
          ? '🎤 رسالة صوتية'
          : message.kind == MessageKind.file
              ? '📎 ${message.attachmentFileName ?? message.text}'
              : message.kind == MessageKind.poll
                  ? '📊 ${message.text}'
                  : message.kind == MessageKind.event
                      ? '📅 ${message.text}'
                      : message.text;
      _updateConversationPreview(conversationId, message, previewOverride: preview);
      if (conversationId != _activeConversationId) {
        final contactMatches = contacts.where((c) => c.internalNumber == senderInternalNumber);
        final senderName = contactMatches.isEmpty ? senderInternalNumber : contactMatches.first.displayName;
        final groupMatches = conversations.where((c) => c.id == conversationId && c.isGroup);
        final notificationTitle = groupMatches.isEmpty ? senderName : '${groupMatches.first.peerDisplayName} • $senderName';
        unawaited(_messageNotifications.showMessageNotification(
          conversationId: conversationId,
          senderName: notificationTitle,
          preview: preview,
        ));
      }
      _safeNotify();
    }));
  }

  /// يحفظ بايتات مرفق وارد (ملف أو صوت) في مجلد مخصَّص لهذه المحادثة ضمن
  /// وثائق التطبيق، ويعيد المسار المحلي الناتج.
  Future<String> _saveIncomingAttachment({
    required String conversationId,
    required String messageId,
    required String fileName,
    required String base64Data,
  }) async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final conversationDir = Directory(
      '${documentsDir.path}${Platform.pathSeparator}local_connect_files${Platform.pathSeparator}$conversationId',
    );
    if (!await conversationDir.exists()) await conversationDir.create(recursive: true);
    final file =
        File('${conversationDir.path}${Platform.pathSeparator}${messageId}_${_sanitizeFileName(fileName)}');
    await file.writeAsBytes(base64Decode(base64Data));
    return file.path;
  }

  /// اسم الملف يصل عبر الشبكة من طرف آخر غير موثوق، ويُستخدم لبناء مسار
  /// ملف محلي — يجب تجريده من أي عناصر مسار (`/`, `\`, `..`) قبل ذلك، وإلا
  /// أمكن لجهاز خبيث إرسال اسم مثل `../../../etc` والكتابة خارج المجلد
  /// المخصَّص للمرفقات.
  String _sanitizeFileName(String rawFileName) {
    final baseName = rawFileName.split(RegExp(r'[\\/]')).last.trim();
    final safe = baseName.replaceAll(RegExp(r'^\.+'), '');
    return safe.isEmpty ? 'file' : safe;
  }
}
