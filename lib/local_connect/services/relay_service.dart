import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// اتصال اختياري بخادم مُرحِّل مركزي (chat.sofinet.cc) — يُستخدَم فقط
/// عندما يتعذّر الوصول المباشر (الطرف الآخر ليس على نفس الشبكة المحلية
/// ولا في مدى بلوتوث/Wi-Fi Direct). ليس بديلًا عن الاتصال المباشر، بل
/// طبقة أخيرة إضافية تحتاج إنترنت فعليًا على الجهازين.
///
/// البروتوكول: `{"to": "<internalNumber>", "payload": {...}}`، حيث
/// payload هي بالضبط نفس حمولة JSON المستخدمة في بروتوكول الشبكة المحلية
/// (type/id/senderInternalNumber/text/...) — لا تكرار لمنطق التسلسل.
class RelayService {
  RelayService({this.host = 'chat.sofinet.cc'});

  final String host;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  String? _currentInternalNumber;
  bool _disposed = false;

  bool _connected = false;
  bool get isConnected => _connected;
  String? lastError;

  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();

  /// حمولات واردة عبر المُرحِّل — بنفس شكل ما يصل عبر TCP/بلوتوث، فتُمرَّر
  /// مباشرة لنفس معالج الرسائل الواردة في AppState.
  Stream<Map<String, dynamic>> get incoming => _incomingController.stream;

  /// يسجّل هذا الجهاز لدى المُرحِّل (اسمه ورقمه، ورقم هاتفه إن وُجد).
  /// فشل هذا الطلب (لا إنترنت غالبًا) لا يمنع بقية التطبيق من العمل —
  /// المُرحِّل طبقة اختيارية بحتة.
  Future<bool> register({
    required String internalNumber,
    required String displayName,
    String? phoneNumber,
  }) async {
    try {
      final body = <String, dynamic>{'internalNumber': internalNumber, 'displayName': displayName};
      if (phoneNumber != null) body['phoneNumber'] = phoneNumber;
      final response = await http
          .post(
            Uri.https(host, '/api/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (error) {
      lastError = 'تعذّر التسجيل لدى المُرحِّل: $error';
      return false;
    }
  }

  /// يبدأ اتصال WebSocket ويحافظ عليه، معيدًا المحاولة تلقائيًا عند
  /// الانقطاع (تغيّر شبكة، إعادة تشغيل الخادم...) بفاصل ثابت بسيط.
  Future<void> connect(String internalNumber) async {
    _currentInternalNumber = internalNumber;
    await _connectOnce();
  }

  Future<void> _connectOnce() async {
    if (_disposed || _currentInternalNumber == null) return;
    try {
      final uri = Uri(
        scheme: 'wss',
        host: host,
        path: '/ws',
        queryParameters: {'internalNumber': _currentInternalNumber},
      );
      final channel = WebSocketChannel.connect(uri);
      await channel.ready;
      _channel = channel;
      _connected = true;
      lastError = null;

      _sub = channel.stream.listen(
        _handleFrame,
        onDone: _handleDisconnect,
        onError: (Object error) {
          lastError = 'خطأ في اتصال المُرحِّل: $error';
          _handleDisconnect();
        },
        cancelOnError: true,
      );
    } catch (error) {
      lastError = 'تعذّر الاتصال بالمُرحِّل: $error';
      _connected = false;
      _scheduleReconnect();
    }
  }

  void _handleFrame(dynamic raw) {
    try {
      final map = jsonDecode(raw as String) as Map<String, dynamic>;
      final payload = map['payload'];
      if (payload is Map<String, dynamic>) {
        _incomingController.add(payload);
      }
    } catch (_) {
      // حمولة غير متوقَّعة من الخادم — تُتجاهَل بدل إسقاط الاتصال بالكامل.
    }
  }

  void _handleDisconnect() {
    _connected = false;
    _channel = null;
    _sub?.cancel();
    _sub = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _connectOnce);
  }

  /// يرسل حمولة لرقم داخلي معيَّن عبر المُرحِّل. يعيد true إذا قُبِلت
  /// الحمولة للإرسال عبر القناة (الخادم نفسه يخزّنها دائمًا بغض النظر عن
  /// كون المستلم متصلًا الآن أم لا)، أو false إن لم نكن متصلين بالمُرحِّل
  /// أصلًا الآن.
  Future<bool> send({required String to, required Map<String, dynamic> payload}) async {
    final channel = _channel;
    if (!_connected || channel == null) return false;
    try {
      channel.sink.add(jsonEncode({'to': to, 'payload': payload}));
      return true;
    } catch (error) {
      lastError = 'تعذّر الإرسال عبر المُرحِّل: $error';
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _incomingController.close();
  }
}
