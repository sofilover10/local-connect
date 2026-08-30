import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/call_session.dart' show CallMediaType;
import '../models/community.dart';
import '../models/contact.dart';
import '../models/conversation.dart';
import '../models/diagnostic_check.dart';
import '../models/message.dart';
import '../models/peer_info.dart';
import '../models/status_post.dart';
import '../utils/text_sanitize.dart';
import 'bluetooth_messaging_service.dart';
import 'bluetooth_transport_service.dart';
import 'call_service.dart';
import 'device_identity_service.dart';
import 'e2ee_service.dart';
import 'native_crash_service.dart';
import 'group_call_service.dart';
import 'lan_discovery_service.dart';
import 'local_store_service.dart';
import 'message_notification_service.dart';
import 'messaging_socket_service.dart';
import 'phone_contacts_service.dart';
import 'relay_service.dart';
import 'update_check_service.dart';
import 'wifi_direct_service.dart';

part 'app_state_communities.dart';
part 'app_state_groups.dart';
part 'app_state_status.dart';
part 'app_state_blocking.dart';
part 'app_state_contacts.dart';
part 'app_state_messaging.dart';
part 'app_state_incoming.dart';
part 'app_state_diagnostics.dart';

/// الحالة المركزية للتطبيق: تربط الهوية، الاكتشاف على الشبكة، النقل عبر
/// المقابس، والتخزين المحلي، وتعرض واجهة واحدة بسيطة للشاشات.
///
/// نموذج التسليم: كل رسالة صادرة تُخزَّن فورًا محليًا بحالة queued، ثم
/// تُحاوَل تسليمها مباشرة إذا كان الطرف الآخر ظاهرًا حاليًا على الشبكة.
/// إن لم يكن ظاهرًا، تبقى في قائمة الانتظار ويُعاد إرسالها تلقائيًا كلما
/// ظهر الطرف الآخر (اكتشاف جديد) أو دوريًا كل بضع ثوانٍ — هذا هو أسلوب
/// "التخزين والإعادة" (store-and-forward) الذي يجعل التطبيق يعمل أوفلاين
/// على الشبكة المحلية دون أي خادم مركزي.
class LocalConnectAppState extends ChangeNotifier with WidgetsBindingObserver {
  LocalConnectAppState({String instanceId = 'default', int messagingPort = 45602})
      : _store = LocalStoreService(instanceId: instanceId),
        socket = MessagingSocketService(preferredPort: messagingPort);

  final LocalStoreService _store;
  late final DeviceIdentityService _identityService = DeviceIdentityService(_store);
  final LanDiscoveryService discovery = LanDiscoveryService();
  final MessagingSocketService socket;

  /// تشفير من طرف لطرف لمحتوى الرسائل (نص/مرفقات) — راجع توثيق [E2eeService]
  /// لتفاصيل التصميم وحدوده. `late final` بدل تهيئة مباشرة لأنه يحتاج
  /// [_store] المُهيَّأ في قائمة تهيئة المُنشئ أولًا.
  late final E2eeService e2ee = E2eeService(_store);
  final PhoneContactsService _phoneContactsService = PhoneContactsService();
  final NativeCrashService _nativeCrash = NativeCrashService();
  final MessageNotificationService _messageNotifications = MessageNotificationService();

  /// معرّف المحادثة المفتوحة حاليًا على الشاشة (إن وُجدت) — تُضبَط من
  /// ChatScreen. رسالة واردة لهذه المحادثة تحديدًا لا تُظهِر إشعارًا (المستخدم
  /// يراها مباشرة أصلًا)، بعكس أي محادثة أخرى.
  String? _activeConversationId;
  void setActiveConversation(String? conversationId) {
    _activeConversationId = conversationId;
    if (conversationId != null) {
      unawaited(_messageNotifications.cancelMessageNotification(conversationId));
    }
  }

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
    contactDisplayNameFor: _contactDisplayNameFor,
  );

  /// مكالمات صوتية جماعية (mesh) — نفس فكرة [callService] لكن لعدة أطراف؛
  /// انظر توثيق GroupCallService لتفاصيل التنسيق بين الأعضاء.
  late final GroupCallService groupCallService = GroupCallService(
    sendSignal: sendCallSignal,
    localInternalNumber: () => identity.internalNumber,
    localDisplayName: () => identity.displayName,
    contactDisplayNameFor: _contactDisplayNameFor,
  );

  /// راجع توثيق CallService._contactDisplayNameFor — يُفضَّل اسم جهة اتصال
  /// محفوظ محليًا على الاسم الذي يدّعيه المتصل نفسه عبر الشبكة.
  String? _contactDisplayNameFor(String internalNumber) {
    final matches = contacts.where((c) => c.internalNumber == internalNumber);
    return matches.isEmpty ? null : matches.first.displayName;
  }

  late DeviceIdentity identity;
  bool isReady = false;
  UpdateInfo? availableUpdate;

  final List<Contact> contacts = [];
  final List<Conversation> conversations = [];

  /// حالات (منشورات مؤقتة 24 ساعة) — لي أو لجهات اتصالي. القائمة تشمل
  /// المنتهية أيضًا حتى تُنظَّف صراحة (انظر [_pruneExpiredStatuses])؛
  /// استخدم [activeStatuses] للعرض دائمًا.
  final List<StatusPost> statuses = [];
  List<StatusPost> get activeStatuses => statuses.where((s) => !s.isExpired).toList();

  /// مجتمعات (حاويات تُجمِّع مجموعات/قنوات موجودة أصلًا) — أنا عضو فيها أو
  /// مالكها.
  final List<Community> communities = [];

  /// أرقام داخلية محظورة — تُفحَص عند كل رسالة/إشارة مكالمة واردة (نقطة
  /// تنفيذ واحدة في [_handleIncomingWire] تغطي الرسائل والمكالمات معًا)،
  /// وأيضًا عند الإرسال (لمنع إرسال رسالة عرَضية لطرف حظرتَه من قبل).
  final Set<String> blockedInternalNumbers = {};
  final Map<String, List<ChatMessage>> _messagesByConversation = {};

  Timer? _retryTimer;
  Timer? _updateCheckTimer;
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
    await e2ee.init();
    await _reportPendingNativeCrash();

    await _loadContacts();
    await _loadConversations();
    blockedInternalNumbers.addAll(_store.blockedBox.keys.cast<String>());
    await _loadStatuses();
    await _loadCommunities();
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
    // init() يُستدعى مرة واحدة فقط طوال عمر العملية (الخدمة الأمامية
    // الدائمة تُبقي العملية والـ LocalConnectAppState نفسه حيّين حتى بعد
    // إغلاق المستخدم للتطبيق وإعادة فتحه لاحقًا)، فبدون هذا المؤقّت الدوري
    // كان فحص التحديث يحدث مرة واحدة فقط عند أول تشغيل، ولا يُعاد أبدًا —
    // أي إصدار جديد يصدر بعدها لن يُكتشَف إطلاقًا ما لم يُغلَق التطبيق
    // إغلاقًا كاملًا (تصفيته من الخلفية فعليًا) ويُعاد فتحه من الصفر.
    _updateCheckTimer = Timer.periodic(const Duration(hours: 6), (_) => _checkForUpdate());

    WidgetsBinding.instance.addObserver(this);
  }

  /// يقرأ أي عطل أصلي (خارج محرّك Dart تمامًا — WebRTC، البلوتوث/Wi-Fi
  /// Direct المكتوبَين يدويًا في الكود الأصلي) حدث في الجلسة السابقة وأنهى
  /// العملية، ويُسجِّله في [errorLog] العادي حتى يظهر في شاشة "فحص
  /// الأخطاء" بدل أن يبقى بلا أي أثر — راجع توثيق CrashReporter.kt.
  Future<void> _reportPendingNativeCrash() async {
    final crash = await _nativeCrash.readPendingCrash();
    if (crash == null || crash.isEmpty) return;
    recordError('عطل أصلي سابق (native crash)', crash.trim());
    await _nativeCrash.clearPendingCrash();
  }

  /// يُبطئ بث اكتشاف الأجهزة (راجع LanDiscoveryService.backgroundBroadcastInterval)
  /// عندما تُغلَق الشاشة أو ينتقل التطبيق للخلفية — خدمة المقدّمة الثابتة
  /// تُبقي العملية حيّة في هذه الحالة أيضًا (بخلاف تطبيق عادي يُعلَّق
  /// بالكامل)، فبث كل ٢٫٥ ثانية بلا توقف طوال هذا الوقت يستنزف البطارية
  /// ملحوظًا بلا داعٍ حقيقي (المستخدم لا ينظر للشاشة أصلًا).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    discovery.setBackgroundMode(state != AppLifecycleState.resumed);
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
  static const _fullScreenIntentPromptKey = 'full_screen_intent_prompted';
  static const _batteryOptimizationPromptKey = 'battery_optimization_prompted';
  Future<void> ensureNotificationPermission() async {
    if (_notificationPermissionRequested) return;
    _notificationPermissionRequested = true;
    try {
      await Permission.notification.request();
    } catch (_) {
      // منصّات/بيئات بلا معالج فعلي لهذه القناة (اختبارات الودجت مثلًا) —
      // لا يجب أن يُسقِط ذلك الشاشة الرئيسية بالكامل.
    }
    // مرة واحدة *فعليًا* عبر عمر التثبيت، لا فقط عبر عمر هذا الكائن —
    // ensureNotificationPermission تُستدعى من أول بناء لشاشة رئيسية، وهذا
    // يتكرر مع كل إعادة تشغيل للعملية (أندرويد قد يقتل الخدمة الخلفية
    // ويُعيد تشغيلها، أو المستخدم يُغلِق التطبيق ويعيد فتحه). بدون هذا
    // التخزين الدائم، فتح شاشة إعدادات "الإشعار بشاشة كاملة" (التالية) كان
    // يتكرر عند كل فتح للتطبيق قبل أن يمنح المستخدم الصلاحية فعليًا — يبدو
    // للمستخدم وكأن التطبيق "يُغلَق" فجأة وينتقل لشاشة أخرى دون تفسير.
    if (_store.identityBox.get(_fullScreenIntentPromptKey) == null) {
      await _store.identityBox.put(_fullScreenIntentPromptKey, 'true');
      unawaited(callService.ensureFullScreenIntentPermission());
    }

    // نفس منطق "مرة واحدة فعليًا عبر عمر التثبيت" أعلاه — بدون استثناء
    // تحسين البطارية، تضع بعض الأجهزة (خصوصًا سامسونج One UI) التطبيق في
    // "سكون عميق" بعد ساعات من الخمول فتقتل خدمة الخلفية الدائمة، فيتوقف
    // استقبال الرسائل/المكالمات تمامًا ويظهر الجهاز "غير متصل" لدى الآخرين
    // بلا أي تفسير — هذا بالضبط ما أبلغ عنه المستخدم (لا يرنّ، ويظهر غير
    // متصل بعد ترك التطبيق لساعات).
    if (_store.identityBox.get(_batteryOptimizationPromptKey) == null) {
      await _store.identityBox.put(_batteryOptimizationPromptKey, 'true');
      try {
        await Permission.ignoreBatteryOptimizations.request();
      } catch (_) {
        // لا شيء — منصّات/بيئات بلا معالج فعلي لهذه القناة.
      }
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

  Future<void> _loadStatuses() async {
    statuses
      ..clear()
      ..addAll(_store.statusBox.values.map((raw) => StatusPost.fromMap(_store.decode(raw))));
    await _pruneExpiredStatuses();
  }

  /// يحذف الحالات المنتهية (أقدم من 24 ساعة) من الذاكرة والتخزين معًا —
  /// [activeStatuses] وحدها تكفي للعرض، لكن بدون هذا التنظيف يتراكم
  /// التخزين إلى الأبد.
  Future<void> _pruneExpiredStatuses() async {
    final expired = statuses.where((s) => s.isExpired).toList();
    if (expired.isEmpty) return;
    statuses.removeWhere((s) => s.isExpired);
    for (final status in expired) {
      await _store.statusBox.delete(status.id);
    }
    _safeNotify();
  }

  Future<void> _loadMessages(String conversationId) async {
    final box = await _store.messagesBoxFor(conversationId);
    _messagesByConversation[conversationId] =
        box.values.map((raw) => ChatMessage.fromMap(_store.decode(raw))).toList()
          ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
  }

  // ---------------------------------------------------------------------
  // إرسال الرسائل
  // ---------------------------------------------------------------------

  // ---------------------------------------------------------------------
  // استقبال الرسائل الواردة
  // ---------------------------------------------------------------------

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

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _updateCheckTimer?.cancel();
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
    groupCallService.dispose();
    super.dispose();
  }
}
