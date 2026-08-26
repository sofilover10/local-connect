import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'bluetooth_transport_service.dart';

/// يؤطّر بروتوكول الرسائل (JSON مفصول بسطر جديد — نفس بروتوكول
/// [MessagingSocketService] بالضبط) فوق تيار البايتات الخام لبلوتوث
/// كلاسيكي. الاتصال هنا "جلسة" قائمة يجب فتحها مرة واحدة والحفاظ عليها،
/// خلافًا لـTCP حيث يُفتح ويُغلق اتصال جديد لكل رسالة.
class BluetoothMessagingService {
  BluetoothMessagingService(this._transport);

  final BluetoothTransportService _transport;

  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incoming => _incomingController.stream;

  /// اكتشاف بلوتوث يعطي فقط اسم الجهاز وعنوانه (لا يعرف رقمنا الداخلي)،
  /// لذا يُرسَل تبادل هوية صغير فور الاتصال بدل مطالبة المستخدم بكتابة
  /// الرقم الداخلي للطرف الآخر يدويًا. أي بطاقة هوية واردة تصل هنا.
  final _helloController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get hello => _helloController.stream;

  final Map<String, StringBuffer> _buffers = {};
  final Set<String> _connectedAddresses = {};
  final Map<String, Completer<bool>> _pendingAcks = {};

  StreamSubscription<Map<String, dynamic>>? _sub;

  void start() {
    _sub = _transport.dataStream.listen(_handleEvent);
  }

  bool isConnected(String address) => _connectedAddresses.contains(address);

  void _handleEvent(Map<String, dynamic> event) {
    final address = event['address'] as String?;
    if (address == null) return;

    if (event['connected'] == true) {
      _connectedAddresses.add(address);
      return;
    }
    if (event['disconnected'] == true) {
      _connectedAddresses.remove(address);
      _buffers.remove(address);
      return;
    }

    final bytes = event['bytes'];
    if (bytes is! Uint8List) return;
    final buffer = _buffers.putIfAbsent(address, () => StringBuffer());
    buffer.write(utf8.decode(bytes, allowMalformed: true));
    _drainLines(address, buffer);
  }

  void _drainLines(String address, StringBuffer buffer) {
    var content = buffer.toString();
    var newlineIndex = content.indexOf('\n');
    while (newlineIndex != -1) {
      final line = content.substring(0, newlineIndex).trim();
      content = content.substring(newlineIndex + 1);
      if (line.isNotEmpty) _handleLine(address, line);
      newlineIndex = content.indexOf('\n');
    }
    buffer
      ..clear()
      ..write(content);
  }

  void _handleLine(String address, String line) {
    Map<String, dynamic> map;
    try {
      map = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    const knownTypes = {
      'message',
      'edit_message',
      'delete_message',
      'poll_vote',
      'group_invite',
      'group_member_update',
      'call_offer',
      'call_answer',
      'call_ice_candidate',
      'call_end',
      'call_reject',
      'group_call_invite',
      'group_call_join',
      'group_call_roster',
    };
    if (knownTypes.contains(map['type'])) {
      _incomingController.add(map);
      final ackLine = '${jsonEncode({'type': 'ack', 'id': map['id']})}\n';
      unawaited(_transport.send(address, Uint8List.fromList(utf8.encode(ackLine))));
    } else if (map['type'] == 'ack') {
      final id = map['id'] as String?;
      if (id != null) _pendingAcks.remove('$address:$id')?.complete(true);
    } else if (map['type'] == 'hello') {
      _helloController.add({...map, 'address': address});
    }
  }

  /// يرسل بطاقة هوية (بدون انتظار إقرار — تبادل بسيط لمرة واحدة، ليس رسالة
  /// محادثة). يفتح اتصالًا إن لم يكن قائمًا بعد.
  Future<bool> sendHello(String address, Map<String, dynamic> identity) async {
    if (!_connectedAddresses.contains(address)) {
      final connected = await _transport.connect(address);
      if (!connected) return false;
      _connectedAddresses.add(address);
    }
    final line = '${jsonEncode({'type': 'hello', ...identity})}\n';
    return _transport.send(address, Uint8List.fromList(utf8.encode(line)));
  }

  /// يرسل رسالة عبر اتصال بلوتوث قائم مع [address]، ويفتح اتصالًا جديدًا
  /// إن لم يكن هناك واحد بعد. ينتظر إقرار استلام (ack) قبل اعتبار التسليم
  /// ناجحًا، بنفس منطق [MessagingSocketService.sendDirect].
  Future<bool> sendDirect({
    required String address,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!_connectedAddresses.contains(address)) {
      final connected = await _transport.connect(address);
      if (!connected) return false;
      _connectedAddresses.add(address);
    }

    final id = payload['id'] as String;
    final completer = Completer<bool>();
    _pendingAcks['$address:$id'] = completer;

    final line = '${jsonEncode(payload)}\n';
    final sent = await _transport.send(address, Uint8List.fromList(utf8.encode(line)));
    if (!sent) {
      _pendingAcks.remove('$address:$id');
      _connectedAddresses.remove(address);
      return false;
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingAcks.remove('$address:$id');
        return false;
      },
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _incomingController.close();
    await _helloController.close();
  }
}
