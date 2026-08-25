import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/conversation.dart';
import '../models/diagnostic_check.dart';
import '../models/message.dart';
import '../models/peer_info.dart';
import 'bluetooth_messaging_service.dart';
import 'bluetooth_transport_service.dart';
import 'device_identity_service.dart';
import 'lan_discovery_service.dart';
import 'local_store_service.dart';
import 'messaging_socket_service.dart';
import 'phone_contacts_service.dart';
import 'update_check_service.dart';
import 'wifi_direct_service.dart';

/// الحالة المركزية للتطبيق: تربط الهوية، الاكتشاف على الشبكة، النقل عبر
/// المقابس، والتخزين المحلي، وتعرض واجهة واحدة بسيطة للشاشات.
///
/// نموذج التسليم: كل رسالة صادرة تُخزَّن فورًا محليًا بحالة queued، ثم
/// تُحاوَل تسليمها مباشرة إذا كان الطرف الآخر ظاهرًا حاليًا على الشبكة.
/// إن لم يكن ظاهرًا، تبقى في قائمة الانتظار ويُعاد إرسالها تلقائيًا كلما
/// ظهر الطرف الآخر (اكتشاف جديد) أو دوريًا كل بضع ثوانٍ — هذا هو أسلوب
/// "التخزين والإعادة" (store-and-forward) الذي يجعل التطبيق يعمل أوفلاين
/// على الشبكة المحلية دون أي خادم مركزي.
class LocalConnectAppState extends ChangeNotifier {
  LocalConnectAppState({String instanceId = 'default', int messagingPort = 45602})
      : _store = LocalStoreService(instanceId: instanceId),
        socket = MessagingSocketService(preferredPort: messagingPort);

  final LocalStoreService _store;
  late final DeviceIdentityService _identityService = DeviceIdentityService(_store);
  final LanDiscoveryService discovery = LanDiscoveryService();
  final MessagingSocketService socket;
  final PhoneContactsService _phoneContactsService = PhoneContactsService();

  /// نقلا بديلان يعملان مباشرة بين جهازين بدون المرور بالراوتر إطلاقًا،
  /// فيتجاوزان أي عزل أجهزة (AP Isolation) قد يفعّله الراوتر على شبكة
  /// Wi-Fi. Wi-Fi Direct يعيد استخدام اكتشاف/مراسلة الشبكة الحاليين
  /// تلقائيًا فور الاتصال (لأنه ينشئ واجهة IP عادية)؛ البلوتوث له بروتوكول
  /// نقل خاص به عبر [bluetoothMessaging] لأنه بدون طبقة IP.
  final WifiDirectService wifiDirect = WifiDirectService();
  final BluetoothTransportService bluetoothTransport = BluetoothTransportService();
  late final BluetoothMessagingService bluetoothMessaging = BluetoothMessagingService(bluetoothTransport);

  final UpdateCheckService _updateCheckService = UpdateCheckService();

  late DeviceIdentity identity;
  bool isReady = false;
  UpdateInfo? availableUpdate;

  final List<Contact> contacts = [];
  final List<Conversation> conversations = [];
  final Map<String, List<ChatMessage>> _messagesByConversation = {};

  Timer? _retryTimer;
  StreamSubscription<List<PeerInfo>>? _peersSub;
  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  StreamSubscription<Map<String, dynamic>>? _bluetoothIncomingSub;
  StreamSubscription<Map<String, dynamic>>? _bluetoothHelloSub;
  final Set<String> _bluetoothHelloRepliedTo = {};

  /// سجل أخطاء صغير في الذاكرة (يُعرض في شاشة "فحص الأخطاء")، يشمل أخطاء
  /// الواجهة غير المتوقَّعة والتي كان يمكن أن تسبب انهيارًا صامتًا.
  static const _maxErrorLogEntries = 50;
  final List<String> errorLog = [];

  void recordError(String context, Object error) {
    errorLog.insert(0, '[${DateTime.now().toIso8601String()}] $context: $error');
    if (errorLog.length > _maxErrorLogEntries) errorLog.removeLast();
    _safeNotify();
  }

  /// عدة عمليات هنا غير متزامنة (فحص الشبكة، الاستقبال...) وقد تحاول
  /// الإخطار بعد إغلاق التطبيق فعليًا (مثلًا المستخدم يغلقه أثناء فحص جارٍ).
  /// ChangeNotifier.notifyListeners() يرمي استثناءً لو استُدعيت بعد dispose،
  /// فهذا الغلاف يتجاهلها بأمان بدل انهيار عملية الإغلاق نفسها.
  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  List<ChatMessage> messagesFor(String conversationId) =>
      List.unmodifiable(_messagesByConversation[conversationId] ?? const []);

  bool isPeerOnline(String internalNumber) =>
      discovery.peerByInternalNumber(internalNumber) != null;

  List<PeerInfo> get nearbyDevices => discovery.currentPeers
      .where((peer) => !contacts.any((c) => c.internalNumber == peer.internalNumber))
      .toList();

  Future<void> init() async {
    await _store.init();
    identity = await _identityService.loadOrCreate(defaultName: 'مستخدم جديد');

    await _loadContacts();
    await _loadConversations();
    for (final conversation in conversations) {
      await _loadMessages(conversation.id);
    }

    _incomingSub = socket.incoming.listen(_handleIncomingWire);
    bluetoothMessaging.start();
    _bluetoothIncomingSub = bluetoothMessaging.incoming.listen(_handleIncomingWire);
    _bluetoothHelloSub = bluetoothMessaging.hello.listen(_handleBluetoothHello);

    final tcpPort = await socket.startServer();
    if (tcpPort > 0) {
      await discovery.start(identity: identity, tcpPort: tcpPort);
    }
    // إذا فشل تفعيل الخدمتين هنا (مثلًا منفذ محجوز)، يبقى التطبيق قابلًا
    // للاستخدام (جهات اتصال، محادثات محلية...) وتظهر المشكلة في شاشة
    // "فحص الأخطاء" مع زر لإعادة المحاولة بدل انهيار الإقلاع بالكامل.

    _peersSub = discovery.peersStream.listen((_) {
      _absorbPeerPhoneNumbers();
      _safeNotify();
      _retryQueuedMessages();
    });
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _retryQueuedMessages());

    isReady = true;
    _safeNotify();

    unawaited(_checkForUpdate());
  }

  /// فحص غير حاجب لوجود إصدار أحدث على GitHub Releases. يفشل بصمت بلا
  /// إنترنت (متوقَّع وطبيعي لتطبيق مصمَّم للعمل أوفلاين بالكامل).
  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final buildNumber = int.tryParse(info.buildNumber);
      if (buildNumber == null) return;
      final update = await _updateCheckService.checkForUpdate(currentBuildNumber: buildNumber);
      if (update == null) return;
      availableUpdate = update;
      _safeNotify();
    } catch (_) {
      // لا شيء — الفحص اختياري تمامًا ولا يجب أن يؤثر على عمل التطبيق.
    }
  }

  /// يطلب صلاحيات البلوتوث اللازمة للاكتشاف/الاتصال. يختلف الاسم المطلوب
  /// حسب إصدار أندرويد (permission_handler يتعامل مع ذلك داخليًا).
  Future<bool> requestBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ].request();
    return statuses[Permission.bluetoothConnect]?.isGranted == true;
  }

  /// يطلب صلاحية اكتشاف Wi-Fi Direct (تختلف حسب إصدار أندرويد أيضًا).
  Future<bool> requestWifiDirectPermissions() async {
    final statuses = await [
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    return statuses[Permission.nearbyWifiDevices]?.isGranted == true ||
        statuses[Permission.locationWhenInUse]?.isGranted == true;
  }

  Future<void> updateDisplayName(String name) async {
    await _identityService.updateDisplayName(identity, name);
    _safeNotify();
  }

  /// ضبط رقم هاتفك الخاص (اختياري). إن ضُبط، يُرفَق تلقائيًا مع بطاقة
  /// حضورك على الشبكة، فيحفظه أي طرف يتواصل معك تلقائيًا في جهة اتصاله بك.
  Future<void> updatePhoneNumber(String? phoneNumber) async {
    await _identityService.updatePhoneNumber(identity, phoneNumber);
    _safeNotify();
  }

  /// كلما ظهر جهاز عبر الاكتشاف التلقائي وشارك رقم هاتفه، وكان لدينا جهة
  /// اتصال محفوظة لنفس الرقم الداخلي بلا رقم هاتف بعد — نحفظه تلقائيًا.
  /// هذا ما يحقق "اطلب رقمه واحفظه" عمليًا دون حوار طلب/موافقة منفصل.
  void _absorbPeerPhoneNumbers() {
    var changed = false;
    for (final peer in discovery.currentPeers) {
      if (peer.phoneNumber == null || peer.phoneNumber!.isEmpty) continue;
      final index = contacts.indexWhere((c) => c.internalNumber == peer.internalNumber);
      if (index == -1 || contacts[index].phoneNumber == peer.phoneNumber) continue;
      final updated = Contact(
        internalNumber: contacts[index].internalNumber,
        displayName: contacts[index].displayName,
        phoneNumber: peer.phoneNumber,
        manualAddress: contacts[index].manualAddress,
        bluetoothAddress: contacts[index].bluetoothAddress,
        addedAt: contacts[index].addedAt,
      );
      contacts[index] = updated;
      unawaited(_store.contactsBox.put(updated.internalNumber, _store.encode(updated.toMap())));
      changed = true;
    }
    if (changed) _safeNotify();
  }

  // ---------------------------------------------------------------------
  // جهات الاتصال والمحادثات
  // ---------------------------------------------------------------------

  Future<void> _loadContacts() async {
    contacts
      ..clear()
      ..addAll(_store.contactsBox.values.map((raw) => Contact.fromMap(_store.decode(raw))));
  }

  Future<void> _loadConversations() async {
    conversations
      ..clear()
      ..addAll(_store.conversationsBox.values
          .map((raw) => Conversation.fromMap(_store.decode(raw))));
  }

  Future<void> _loadMessages(String conversationId) async {
    final box = await _store.messagesBoxFor(conversationId);
    _messagesByConversation[conversationId] =
        box.values.map((raw) => ChatMessage.fromMap(_store.decode(raw))).toList()
          ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
  }

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

  // ---------------------------------------------------------------------
  // إرسال الرسائل
  // ---------------------------------------------------------------------

  Future<void> sendMessage({required String conversationId, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

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
  Future<void> sendAttachment({
    required String conversationId,
    required String filePath,
    required MessageKind kind,
    String? mimeType,
    String? caption,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      recordError('إرسال مرفق', 'الملف غير موجود: $filePath');
      return;
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
  }

  Future<void> _attemptDelivery(ChatMessage message) async {
    final conversation = conversations.firstWhere((c) => c.id == message.conversationId);

    String? base64Data;
    if (message.kind != MessageKind.text) {
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
    final delivered = await _deliverViaAnyTransport(conversation, payload);

    message.status = delivered ? MessageStatus.delivered : MessageStatus.failed;
    await _persistMessage(message);
    _safeNotify();
  }

  /// يجرّب كل وسيلة اتصال متاحة بالترتيب حتى تنجح واحدة: Wi-Fi المكتشَف
  /// تلقائيًا، ثم عنوان IP يدوي (Wi-Fi أيضًا)، ثم بلوتوث كلاسيكي — الأخيران
  /// يعملان حتى لو لم يظهر الطرف عبر اكتشاف UDP إطلاقًا (مثلًا بسبب عزل
  /// أجهزة على الراوتر). يبقى queued تلقائيًا إن فشلت كل الوسائل، لإعادة
  /// المحاولة لاحقًا.
  Future<bool> _deliverViaAnyTransport(Conversation conversation, Map<String, dynamic> payload) async {
    final peer = discovery.peerByInternalNumber(conversation.peerInternalNumber);
    if (peer != null) {
      final delivered =
          await socket.sendDirect(address: peer.address, port: peer.tcpPort, payload: payload);
      if (delivered) return true;
    }

    final matches = contacts.where((c) => c.internalNumber == conversation.peerInternalNumber);
    final contact = matches.isEmpty ? null : matches.first;

    final manualAddress = contact?.manualAddress;
    if (manualAddress != null) {
      final parsed = InternetAddress.tryParse(manualAddress);
      if (parsed != null) {
        final delivered =
            await socket.sendDirect(address: parsed, port: socket.preferredPort, payload: payload);
        if (delivered) return true;
      }
    }

    final bluetoothAddress = contact?.bluetoothAddress;
    if (bluetoothAddress != null) {
      final delivered = await bluetoothMessaging.sendDirect(address: bluetoothAddress, payload: payload);
      if (delivered) return true;
    }

    return false;
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

  // ---------------------------------------------------------------------
  // استقبال الرسائل الواردة
  // ---------------------------------------------------------------------

  /// أي جهاز على الشبكة المحلية يمكنه فتح اتصال TCP وإرسال JSON تعسفي، لذا
  /// يجب عدم الوثوق ببنية الحمولة الواردة؛ حزمة مشوَّهة يجب أن تُهمَل
  /// وتُسجَّل في سجل الأخطاء بدل أن تُسقِط معالجة الرسائل بالكامل.
  void _handleIncomingWire(Map<String, dynamic> payload) {
    try {
      final id = payload['id'];
      final senderInternalNumber = payload['senderInternalNumber'];
      final text = payload['text'];
      if (id is! String ||
          senderInternalNumber is! String ||
          text is! String ||
          !_isSafeIdentifier(senderInternalNumber)) {
        // senderInternalNumber يُستخدم لاحقًا لبناء معرّف المحادثة، الذي
        // يُستخدم بدوره كاسم صندوق تخزين (Hive) واسم مجلد مرفقات على
        // القرص — رفض أي قيمة تحتوي أحرفًا خارج نطاق آمن (بدل محاولة
        // "تنظيفها") يمنع أي محاولة اجتياز مسار (path traversal) من جهاز
        // آخر على الشبكة منذ البداية.
        recordError('رسالة واردة', 'حمولة غير صالحة من الشبكة تم تجاهلها');
        return;
      }

      // يُحسَب معرّف المحادثة محليًا دائمًا من رقمَي الطرفين، ولا يُوثَق به
      // إن أرسله الطرف الآخر ضمن الحمولة — فهو مُشتقّ بشكل حتمي أصلًا (نفس
      // الحساب يُنتج نفس المعرّف على الطرفين)، وتصديقه من الشبكة كان سيسمح
      // بحقنه بقيمة تعسفية تُستخدَم لاحقًا كاسم صندوق تخزين ومجلد ملفات.
      final conversationId = Conversation.idFor(identity.internalNumber, senderInternalNumber);

      final kind = MessageKind.values.byName((payload['kind'] as String?) ?? 'text');
      final attachmentFileName = payload['attachmentFileName'] as String?;
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
        attachmentFileName: attachmentFileName,
        attachmentMimeType: payload['attachmentMimeType'] as String?,
        attachmentSizeBytes: payload['attachmentSizeBytes'] as int?,
      );

      _handleValidIncomingMessage(conversationId, senderInternalNumber, message, base64Data);
    } catch (error) {
      recordError('معالجة رسالة واردة', error);
    }
  }

  void _handleValidIncomingMessage(
    String conversationId,
    String senderInternalNumber,
    ChatMessage message,
    String? base64Data,
  ) {
    unawaited(_ensureConversation(
      internalNumber: senderInternalNumber,
      displayName: senderInternalNumber,
    ).then((_) async {
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
      _updateConversationPreview(
        conversationId,
        message,
        previewOverride: message.kind == MessageKind.voice
            ? '🎤 رسالة صوتية'
            : message.kind == MessageKind.file
                ? '📎 ${message.attachmentFileName ?? message.text}'
                : null,
      );
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

  /// أرقام داخلية شرعية من هذا التطبيق تكون دائمًا بصيغة `LC-XXXXXX`. أي
  /// حروف خارج هذا النطاق الآمن (حروف/أرقام/شرطة/شرطة سفلية) تُرفَض بدل
  /// السماح بها، لأن هذه القيمة تُستخدم لاحقًا كجزء من اسم صندوق تخزين
  /// ومجلد على القرص.
  static final _safeIdentifierPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  bool _isSafeIdentifier(String value) =>
      value.isNotEmpty && _safeIdentifierPattern.hasMatch(value);

  // ---------------------------------------------------------------------
  // مساعدات التخزين
  // ---------------------------------------------------------------------

  Future<void> _persistMessage(ChatMessage message) async {
    final box = await _store.messagesBoxFor(message.conversationId);
    await box.put(message.id, _store.encode(message.toMap()));
  }

  void _updateConversationPreview(
    String conversationId,
    ChatMessage message, {
    String? previewOverride,
  }) {
    final conversation = conversations.firstWhere((c) => c.id == conversationId);
    conversation
      ..lastMessagePreview = previewOverride ?? message.text
      ..lastMessageAt = message.sentAt;
    unawaited(_store.conversationsBox.put(conversationId, _store.encode(conversation.toMap())));
  }

  // ---------------------------------------------------------------------
  // فحص الأخطاء والإصلاح الذاتي
  // ---------------------------------------------------------------------

  /// يفحص حالة الشبكة والاتصال، ويحاول إصلاح أي خدمة متوقفة (مثلًا بسبب
  /// منفذ كان محجوزًا عند الإقلاع) قبل إعادة عرض النتيجة. يُستدعى من شاشة
  /// "فحص الأخطاء" عند فتحها وعند الضغط على "إعادة الفحص والإصلاح".
  Future<List<DiagnosticCheck>> runDiagnostics() async {
    final checks = <DiagnosticCheck>[];

    if (!socket.isActive) {
      final port = await socket.restart();
      if (port > 0 && !discovery.isActive) {
        await discovery.start(identity: identity, tcpPort: port);
      }
    }
    checks.add(DiagnosticCheck(
      label: 'استقبال الرسائل (TCP)',
      ok: socket.isActive,
      detail: socket.isActive
          ? 'يعمل على المنفذ ${socket.boundPort}'
          : (socket.lastError ?? 'غير مفعّل لسبب غير معروف'),
    ));

    if (!discovery.isActive && socket.isActive) {
      await discovery.restart();
    }
    String discoveryDetail;
    if (!discovery.isActive) {
      discoveryDetail = discovery.lastError ?? 'غير مفعّل لسبب غير معروف';
    } else if (discovery.lastBroadcastError != null) {
      discoveryDetail = discovery.lastBroadcastError!;
    } else if (discovery.currentPeers.isEmpty) {
      // البث يعمل بلا أخطاء لكن لا أحد يظهر — إما لا يوجد جهاز آخر شغّال
      // فعليًا حاليًا، أو (وهذا شائع جدًا) الراوتر يفعّل "عزل الأجهزة"
      // (AP/Client Isolation) فيمنع وصول البث بين الأجهزة رغم اتصالها
      // بنفس الشبكة — لا يوجد إصلاح برمجي لهذا، فقط تعطيله من إعدادات
      // الراوتر، أو استخدام "إضافة بعنوان IP" كبديل مضمون.
      discoveryDetail = 'يعمل على المنفذ ${discovery.udpPort} — لا يظهر أي جهاز حاليًا. '
          'إن كان الجهاز الآخر شغّالًا فعلًا على نفس الشبكة، جرّب تعطيل "عزل الأجهزة/الضيوف" '
          '(AP أو Client Isolation) من إعدادات الراوتر، أو استخدم "إضافة يدوية بعنوان IP".';
    } else {
      discoveryDetail = 'يعمل على المنفذ ${discovery.udpPort} — ${discovery.currentPeers.length} جهاز ظاهر الآن';
    }
    checks.add(DiagnosticCheck(
      label: 'اكتشاف الأجهزة القريبة (بث UDP)',
      ok: discovery.isActive && discovery.lastBroadcastError == null,
      detail: discoveryDetail,
    ));

    try {
      final interfaces =
          await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      final addresses =
          interfaces.expand((i) => i.addresses.map((a) => '${i.name}: ${a.address}')).toList();
      checks.add(DiagnosticCheck(
        label: 'واجهات الشبكة المحلية',
        ok: addresses.isNotEmpty,
        detail: addresses.isEmpty
            ? 'لا توجد واجهة شبكة نشطة — تأكد من الاتصال بشبكة Wi-Fi أو إيثرنت'
            : addresses.join('، '),
      ));
    } catch (error) {
      checks.add(DiagnosticCheck(label: 'واجهات الشبكة المحلية', ok: false, detail: 'تعذر القراءة: $error'));
    }

    final pendingCount = _messagesByConversation.values.expand((m) => m).where(
          (m) => m.outgoing && (m.status == MessageStatus.queued || m.status == MessageStatus.failed),
        ).length;
    checks.add(DiagnosticCheck(
      label: 'رسائل بانتظار التسليم',
      ok: pendingCount == 0,
      detail: pendingCount == 0
          ? 'لا توجد رسائل معلّقة'
          : '$pendingCount رسالة ستُعاد تلقائيًا عند ظهور الطرف الآخر على الشبكة',
    ));

    _safeNotify();
    return checks;
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _peersSub?.cancel();
    _incomingSub?.cancel();
    _bluetoothIncomingSub?.cancel();
    _bluetoothHelloSub?.cancel();
    discovery.stop();
    socket.stop();
    bluetoothMessaging.stop();
    super.dispose();
  }
}
