part of 'app_state.dart';

/// إدارة جهات الاتصال، وربط الظهور على الشبكة/بلوتوث بمحادثة قائمة.
extension ContactsExtension on LocalConnectAppState {
  Future<Conversation> addContact({
    required String internalNumber,
    required String displayName,
    String? phoneNumber,
    String? manualAddress,
    String? bluetoothAddress,
  }) async {
    final existingIndex = contacts.indexWhere((c) => c.internalNumber == internalNumber);
    // إبقاء أي عنوان بديل مضبوط مسبقًا لهذه الجهة إن لم يُمرَّر عنوان جديد
    // صراحة الآن — إضافة جهة اتصال عبر مسار واحد (مثلًا عبر بلوتوث) لا
    // يجب أن تمحو عنوان IP يدوي أُضيف سابقًا عبر مسار آخر، والعكس صحيح.
    final existing = existingIndex == -1 ? null : contacts[existingIndex];
    final contact = Contact(
      internalNumber: internalNumber,
      displayName: displayName,
      phoneNumber: phoneNumber ?? existing?.phoneNumber,
      manualAddress: manualAddress ?? existing?.manualAddress,
      bluetoothAddress: bluetoothAddress ?? existing?.bluetoothAddress,
    );
    if (existingIndex == -1) {
      contacts.add(contact);
    } else {
      // تحديث بدل التجاهل: لو أعاد المستخدم إضافة نفس الرقم بعنوان IP جديد
      // (تغيّر عنوانه)، يجب أن يُحدَّث بدل بقاء العنوان القديم عالقًا.
      contacts[existingIndex] = contact;
    }
    await _store.contactsBox.put(internalNumber, _store.encode(contact.toMap()));
    return _ensureConversation(internalNumber: internalNumber, displayName: displayName);
  }

  /// يعيد تسمية جهة اتصال قائمة بالفعل — يُحدِّث اسمها في قائمة جهات
  /// الاتصال **وفي عنوان محادثتها** معًا (الاثنان يُخزَّنان منفصلين محليًا؛
  /// [addContact] وحده لا يُحدِّث اسم محادثة قائمة أصلًا، فيبقى الاسم القديم
  /// عالقًا في قائمة المحادثات دون هذا التحديث الصريح).
  Future<void> renameContact(
    String internalNumber,
    String newDisplayName, {
    String? newPhoneNumber,
  }) async {
    final trimmed = newDisplayName.trim();
    if (trimmed.isEmpty) return;

    final contactIndex = contacts.indexWhere((c) => c.internalNumber == internalNumber);
    if (contactIndex != -1) {
      final existing = contacts[contactIndex];
      final updated = Contact(
        internalNumber: existing.internalNumber,
        displayName: trimmed,
        phoneNumber: newPhoneNumber ?? existing.phoneNumber,
        manualAddress: existing.manualAddress,
        bluetoothAddress: existing.bluetoothAddress,
        addedAt: existing.addedAt,
      );
      contacts[contactIndex] = updated;
      await _store.contactsBox.put(internalNumber, _store.encode(updated.toMap()));
    }

    final conversationIndex = conversations.indexWhere((c) => c.peerInternalNumber == internalNumber);
    if (conversationIndex != -1) {
      final conversation = conversations[conversationIndex];
      conversation.peerDisplayName = trimmed;
      await _store.conversationsBox.put(conversation.id, _store.encode(conversation.toMap()));
    }

    _safeNotify();
  }

  /// يحفظ جهة اتصال LocalConnect في دفتر جهات اتصال الهاتف الفعلي (خارج
  /// التطبيق). يعيد true عند النجاح، أو false مع تسجيل السبب في سجل
  /// الأخطاء (رفض الصلاحية غالبًا) ليعرضه الطرف المستدعي للمستخدم.
  Future<bool> saveContactToPhoneBook(String internalNumber) async {
    final match = contacts.where((c) => c.internalNumber == internalNumber);
    if (match.isEmpty) return false;
    try {
      await _phoneContactsService.saveToPhoneContacts(match.first);
      return true;
    } catch (error) {
      recordError('حفظ في جهات اتصال الهاتف', error);
      return false;
    }
  }

  Future<Conversation> addContactFromPeer(PeerInfo peer) => addContact(
        internalNumber: peer.internalNumber,
        displayName: peer.displayName,
        phoneNumber: peer.phoneNumber,
      );

  /// يبدأ (أو يستأنف) اتصال بلوتوث بجهاز مكتشَف عبر عنوانه، ويرسل بطاقة
  /// هويتنا فورًا. الطرف الآخر يضيفنا تلقائيًا كجهة اتصال ويردّ ببطاقته هو،
  /// فنضيفه نحن أيضًا تلقائيًا دون أي إدخال يدوي لرقمه الداخلي — انظر
  /// [_handleBluetoothHello].
  Future<bool> connectBluetoothDevice(String address) => bluetoothMessaging.sendHello(address, {
        'internalNumber': identity.internalNumber,
        'displayName': identity.displayName,
        if (identity.phoneNumber != null) 'phoneNumber': identity.phoneNumber,
      });

  void _handleBluetoothHello(Map<String, dynamic> payload) {
    try {
      final address = payload['address'];
      final internalNumber = payload['internalNumber'];
      if (address is! String || internalNumber is! String || !_isSafeIdentifier(internalNumber)) {
        recordError('تبادل هوية بلوتوث', 'بطاقة هوية غير صالحة تم تجاهلها');
        return;
      }
      final displayName = payload['displayName'] as String? ?? internalNumber;
      unawaited(addContact(
        internalNumber: internalNumber,
        displayName: displayName,
        phoneNumber: payload['phoneNumber'] as String?,
        bluetoothAddress: address,
      ));

      if (_bluetoothHelloRepliedTo.add(address)) {
        unawaited(bluetoothMessaging.sendHello(address, {
          'internalNumber': identity.internalNumber,
          'displayName': identity.displayName,
          if (identity.phoneNumber != null) 'phoneNumber': identity.phoneNumber,
        }));
      }
    } catch (error) {
      recordError('تبادل هوية بلوتوث', error);
    }
  }

  Future<Conversation> _ensureConversation({
    required String internalNumber,
    required String displayName,
  }) async {
    final id = Conversation.idFor(identity.internalNumber, internalNumber);
    final existing = conversations.where((c) => c.id == id);
    if (existing.isNotEmpty) return existing.first;

    final conversation = Conversation(
      id: id,
      peerInternalNumber: internalNumber,
      peerDisplayName: displayName,
    );
    conversations.add(conversation);
    _messagesByConversation[id] = [];
    await _store.conversationsBox.put(id, _store.encode(conversation.toMap()));
    _safeNotify();
    return conversation;
  }
}
