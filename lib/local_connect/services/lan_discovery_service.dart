import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/peer_info.dart';
import 'device_identity_service.dart';

/// اكتشاف الأجهزة الأخرى على نفس الشبكة المحلية عبر بث UDP دوري (broadcast).
///
/// كل جهاز يبث بطاقة حضور "presence" كل [broadcastInterval]، وأي جهاز آخر
/// يستقبلها يضيف/يحدّث مُرسِلها في قائمة الأجهزة الظاهرة حاليًا. لا حاجة
/// لأي خادم مركزي أو إعداد مسبق؛ يعمل طالما الأجهزة على نفس الشبكة الفرعية.
class LanDiscoveryService {
  LanDiscoveryService({
    this.udpPort = 45601,
    this.broadcastInterval = const Duration(seconds: 2, milliseconds: 500),
    this.staleTimeout = const Duration(seconds: 8),
  });

  final int udpPort;
  final Duration broadcastInterval;
  final Duration staleTimeout;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;

  final Map<String, PeerInfo> _peersByInternalNumber = {};
  final _peersController = StreamController<List<PeerInfo>>.broadcast();

  /// آخر خطأ حدث أثناء محاولة تفعيل الاكتشاف (مثلًا: المنفذ مستخدَم من
  /// برنامج آخر على نفس الجهاز)، أو null إذا كان الاكتشاف يعمل بلا مشاكل.
  String? lastError;

  /// آخر خطأ أثناء محاولة البث الفعلي (مختلف عن فشل ربط المنفذ نفسه) —
  /// مهم لأن Android قد يقبل ربط المقبس لكن يفشل إرسال البث فعليًا.
  String? lastBroadcastError;
  bool get isActive => _socket != null;

  Stream<List<PeerInfo>> get peersStream => _peersController.stream;
  List<PeerInfo> get currentPeers =>
      _peersByInternalNumber.values.toList(growable: false);

  DeviceIdentity? _identity;
  int? _tcpPort;

  /// يحاول ربط منفذ الاكتشاف وبدء البث. لا يرمي استثناءً عند الفشل — بدلًا
  /// من ذلك يسجّل السبب في [lastError] ليعرضه المستخدم في شاشة الفحص
  /// ويعيد المحاولة لاحقًا، بدل أن يمنع بقية التطبيق من العمل.
  Future<void> start({
    required DeviceIdentity identity,
    required int tcpPort,
  }) async {
    _identity = identity;
    _tcpPort = tcpPort;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
      _socket!.broadcastEnabled = true;
      lastError = null;
    } catch (error) {
      lastError = 'تعذر تفعيل اكتشاف الأجهزة على المنفذ $udpPort: $error';
      return;
    }

    _socket!.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = _socket!.receive();
        if (datagram == null) return;
        _handleIncoming(datagram, selfInternalNumber: identity.internalNumber);
      },
      // بدون هذا، أي خطأ يصل عبر تيار المقبس (لا عبر استثناء متزامن من
      // send()) يهرب كخطأ Zone غير مُلتقَط بالكامل — يظهر في سجل الأخطاء
      // العام المبهم بدل أن يُسجَّل هنا بوضوح كخطأ اكتشاف شبكة محدَّد.
      onError: (Object error) {
        lastBroadcastError = 'خطأ في مقبس الاكتشاف: $error';
      },
    );

    _broadcastTimer = Timer.periodic(broadcastInterval, (_) {
      unawaited(_broadcastPresence(identity: identity, tcpPort: tcpPort));
    });
    // بث فوري أول مرة بدل انتظار أول دورة.
    await _broadcastPresence(identity: identity, tcpPort: tcpPort);

    _pruneTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pruneStale());
  }

  /// يوقف الاكتشاف الحالي (إن كان يعمل) ويعيد محاولة تفعيله من جديد.
  /// يُستخدم من شاشة الفحص عند إصلاح المشكلة (مثلًا إغلاق البرنامج الآخر
  /// الذي كان يحجز المنفذ).
  Future<void> restart() async {
    final identity = _identity;
    final tcpPort = _tcpPort;
    if (identity == null || tcpPort == null) return;
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    _socket = null;
    await start(identity: identity, tcpPort: tcpPort);
  }

  /// يبث بطاقة الحضور على **كل** عنوان بث مناسب يمكن الوصول إليه، بدل
  /// الاعتماد فقط على عنوان البث العام 255.255.255.255.
  ///
  /// السبب: على أندرويد عندما تكون شريحة البيانات (mobile data) مفعّلة
  /// بجانب Wi-Fi، قد يختار النظام إرسال حزمة إلى 255.255.255.255 عبر واجهة
  /// خاطئة (بيانات الجوال) بدل واجهة Wi-Fi الفعلية، فلا يصل البث أبدًا
  /// للجهاز الآخر رغم أنهما على نفس شبكة Wi-Fi. حساب عنوان بث موجَّه لكل
  /// واجهة شبكة نشطة (بافتراض قناع شبكي 24/) يجبر توجيه الحزمة عبر
  /// الواجهة الصحيحة فعليًا، أيًّا كان مدى عناوين تلك الشبكة.
  Future<void> _broadcastPresence({
    required DeviceIdentity identity,
    required int tcpPort,
  }) async {
    final socket = _socket;
    if (socket == null) return;
    final payload = jsonEncode({
      'type': 'presence',
      'internalNumber': identity.internalNumber,
      'displayName': identity.displayName,
      'tcpPort': tcpPort,
      if (identity.phoneNumber != null) 'phoneNumber': identity.phoneNumber,
    });
    final bytes = utf8.encode(payload);

    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final interfaces =
          await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        // واجهات بيانات الجوال (rmnet/ccmni/wwan/pdp حسب الشريحة والمصنّع)
        // لا تدعم البث أصلًا، وأندرويد يرفض إرسال أي حزمة بث عليها فعليًا
        // (EPERM) — تجربتها فقط تنتج ضجيجًا في سجل الأخطاء بلا أي فائدة.
        if (_isCellularInterface(interface.name)) continue;
        for (final address in interface.addresses) {
          final directedBroadcast = _subnetBroadcastAddress(address.address);
          if (directedBroadcast != null) targets.add(InternetAddress(directedBroadcast));
        }
      }
    } catch (_) {
      // إن تعذّرت قراءة الواجهات، نكتفي بعنوان البث العام كما كان سابقًا.
    }

    var anySucceeded = false;
    Object? lastFailure;
    for (final target in targets) {
      try {
        socket.send(bytes, target, udpPort);
        anySucceeded = true;
      } catch (error) {
        lastFailure = error;
      }
    }

    lastBroadcastError = anySucceeded
        ? null
        : 'تعذر بث الحضور على أي واجهة شبكة: ${lastFailure ?? "سبب غير معروف"}';
  }

  /// يحسب عنوان بث موجَّه بافتراض قناع شبكي 24/ (الأكثر شيوعًا على شبكات
  /// المنازل ونقاط اتصال الجوال)، بأخذ أول ثلاث خانات من العنوان المحلي
  /// واستبدال الخانة الأخيرة بـ 255. مثال: 192.168.1.23 → 192.168.1.255.
  static const _cellularInterfacePrefixes = ['rmnet', 'ccmni', 'wwan', 'pdp'];
  bool _isCellularInterface(String name) {
    final lower = name.toLowerCase();
    return _cellularInterfacePrefixes.any(lower.startsWith);
  }

  String? _subnetBroadcastAddress(String ipv4) {
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  void _handleIncoming(Datagram datagram, {required String selfInternalNumber}) {
    Map<String, dynamic> map;
    try {
      map = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (map['type'] != 'presence') return;

    final internalNumber = map['internalNumber'] as String?;
    if (internalNumber == null || internalNumber == selfInternalNumber) return;

    final peer = PeerInfo(
      internalNumber: internalNumber,
      displayName: map['displayName'] as String? ?? internalNumber,
      address: datagram.address,
      tcpPort: map['tcpPort'] as int? ?? 0,
      lastSeen: DateTime.now(),
      phoneNumber: map['phoneNumber'] as String?,
    );
    _peersByInternalNumber[internalNumber] = peer;
    _emit();
  }

  void _pruneStale() {
    final now = DateTime.now();
    final before = _peersByInternalNumber.length;
    _peersByInternalNumber.removeWhere((_, peer) => peer.isStaleAt(now, staleTimeout));
    if (_peersByInternalNumber.length != before) _emit();
  }

  void _emit() => _peersController.add(currentPeers);

  PeerInfo? peerByInternalNumber(String internalNumber) =>
      _peersByInternalNumber[internalNumber];

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    await _peersController.close();
  }
}
