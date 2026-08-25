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
import 'call_service.dart';
import 'device_identity_service.dart';
import 'lan_discovery_service.dart';
import 'local_store_service.dart';
import 'messaging_socket_service.dart';
import 'phone_contacts_service.dart';
import 'relay_service.dart';
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

  /// طبقة أخيرة اختيارية: مُرحِّل مركزي عبر الإنترنت (chat.sofinet.cc)
  /// يُستخدَم فقط عندما تفشل كل الوسائل المباشرة (نفس الشبكة، بلوتوث،
  /// Wi-Fi Direct) — مثلًا الطرفان على شبكتين مختلفتين تمامًا. التطبيق
  /// يعمل بالكامل بدونه؛ فشل الاتصال به لا يُعطِّل أي شيء آخر.
  final RelayService relay = RelayService();

  /// مكالمات صوتية/مرئية عبر WebRTC، تستخدم [sendCallSignal] لإرسال إشاراتها
  /// (عروض/ردود/مرشّحات ICE) عبر نفس سلسلة النقل الاحتياطية المستخدمة
  /// للرسائل النصية. تُبنى كـcallback بدل استيراد مباشر لتفادي اعتماد دائري
  /// بين الخدمتين، ولأن identity غير جاهز بعد وقت الإنشاء (late، يُضبط في init).
  late final CallService callService = CallService(
    sendSignal: sendCallSignal,
    localInternalNumber: () => identity.internalNumber,
    localDisplayName: () => identity.displayName,
  );

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
  StreamSubscription<Map<String, dynamic>>? _relayIncomingSub;
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
    _relayIncomingSub = relay.incoming.listen(_handleIncomingWire);
    // تسجيل واتصال بالمُرحِّل بلا انتظار — يحتاج إنترنت فعليًا، ويجب ألا
    // يؤخّر إقلاع التطبيق (الذي يعمل بالكامل أوفلاين بدونه).
    unawaited(_registerAndConnectRelay());

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

  /// يطلب صلاحية إظهار الإشعار الثابت لخدمة الخلفية (إلزامية على أندرويد
  /// 13+ عبر POST_NOTIFICATIONS، وإلا لا يظهر الإشعار رغم أن الخدمة نفسها
  /// تبقى تعمل). تُستدعى مرة واحدة فقط من أول شاشة رئيسية تُبنى، حيث
  /// تكون شاشة (Activity) فعليًا متصلة ليمكن عرض حوار النظام.
  bool _notificationPermissionRequested = false;
  Future<void> ensureNotificationPermission() async {
    if (_notificationPermissionRequested) return;
    _notificationPermissionRequested = true;
    try {
      await Permission.notification.request();
    } catch (_) {
      // منصّات/بيئات بلا معالج فعلي لهذه القناة (اختبارات الودجت مثلًا) —
      // لا يجب أن يُسقِط ذلك الشاشة الرئيسية بالكامل.
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
    unawaited(_registerWithRelay());
  }

  /// ضبط رقم هاتفك الخاص (اختياري). إن ضُبط، يُرفَق تلقائيًا مع بطاقة
  /// حضورك على الشبكة، فيحفظه أي طرف يتواصل معك تلقائيًا في جهة اتصاله بك.
  Future<void> updatePhoneNumber(String? phoneNumber) async {
    await _identityService.updatePhoneNumber(identity, phoneNumber);
    _safeNotify();
    unawaited(_registerWithRelay());
  }

  Future<void> _registerAndConnectRelay() async {
    await _registerWithRelay();
    await relay.connect(identity.internalNumber);
  }

  Future<void> _registerWithRelay() => relay.register(
        internalNumber: identity.internalNumber,
        displayName: identity.displayName,
        phoneNumber: identity.phoneNumber,
      );

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
    message.status = await _deliverViaAnyTransport(conversation.peerInternalNumber, payload);
    await _persistMessage(message);
    _safeNotify();
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
    final peer = discovery.peerByInternalNumber(peerInternalNumber);
    if (peer != null) {
      final delivered =
          await socket.sendDirect(address: peer.address, port: peer.tcpPort, payload: payload);
      if (delivered) return MessageStatus.delivered;
    }

    final matches = contacts.where((c) => c.internalNumber == peerInternalNumber);
    final contact = matches.isEmpty ? null : matches.first;

    final manualAddress = contact?.manualAddress;
    if (manualAddress != null) {
      final parsed = InternetAddress.tryParse(manualAddress);
      if (parsed != null) {
        final delivered =
            await socket.sendDirect(address: parsed, port: socket.preferredPort, payload: payload);
        if (delivered) return MessageStatus.delivered;
      }
    }

    final bluetoothAddress = contact?.bluetoothAddress;
    if (bluetoothAddress != null) {
      final delivered = await bluetoothMessaging.sendDirect(address: bluetoothAddress, payload: payload);
      if (delivered) return MessageStatus.delivered;
    }

    final sentViaRelay = await relay.send(to: peerInternalNumber, payload: payload);
    if (sentViaRelay) return MessageStatus.sent;

    return MessageStatus.failed;
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

  // ---------------------------------------------------------------------
  // تعديل/حذف الرسائل وأرشفة المحادثات
  // ---------------------------------------------------------------------

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
    unawaited(_deliverViaAnyTransport(conversation.peerInternalNumber, {
      'type': 'edit_message',
      'id': message.id,
      'senderInternalNumber': identity.internalNumber,
      'text': trimmed,
      'editedAt': message.editedAt!.toIso8601String(),
    }));
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
      unawaited(_deliverViaAnyTransport(conversation.peerInternalNumber, {
        'type': 'delete_message',
        'id': message.id,
        'senderInternalNumber': identity.internalNumber,
      }));
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

  // ---------------------------------------------------------------------
  // استقبال الرسائل الواردة
  // ---------------------------------------------------------------------

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

      // يُحسَب معرّف المحادثة محليًا دائمًا من رقمَي الطرفين، ولا يُوثَق به
      // إن أرسله الطرف الآخر ضمن الحمولة — فهو مُشتقّ بشكل حتمي أصلًا (نفس
      // الحساب يُنتج نفس المعرّف على الطرفين)، وتصديقه من الشبكة كان سيسمح
      // بحقنه بقيمة تعسفية تُستخدَم لاحقًا كاسم صندوق تخزين ومجلد ملفات.
      final conversationId = Conversation.idFor(identity.internalNumber, senderInternalNumber);

      switch (payload['type']) {
        case 'edit_message':
          _handleIncomingEdit(conversationId, senderInternalNumber, payload);
          return;
        case 'delete_message':
          _handleIncomingDelete(conversationId, senderInternalNumber, payload);
          return;
        case 'call_offer':
        case 'call_answer':
        case 'call_ice_candidate':
        case 'call_reject':
        case 'call_end':
          // إشارات المكالمات لا تُخزَّن كرسائل محادثة — تُمرَّر مباشرة إلى
          // CallService الذي يدير حالتها الخاصة.
          unawaited(callService.handleSignal(payload));
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

    checks.add(DiagnosticCheck(
      label: 'المُرحِّل المركزي (اختياري، عبر الإنترنت)',
      ok: relay.isConnected,
      detail: relay.isConnected
          ? 'متصل — يعمل كخطة بديلة أخيرة إذا تعذّر الوصول المباشر'
          : (relay.lastError ?? 'غير متصل حاليًا (طبيعي بلا إنترنت؛ يعيد المحاولة تلقائيًا)'),
    ));

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
    _relayIncomingSub?.cancel();
    discovery.stop();
    socket.stop();
    bluetoothMessaging.stop();
    unawaited(relay.dispose());
    callService.dispose();
    super.dispose();
  }
}
