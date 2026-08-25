import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// نقل الرسائل مباشرة بين جهازين عبر TCP (اتصال مباشر Peer-to-Peer)، دون
/// المرور بأي خادم وسيط. كل جهاز يشغّل خادم TCP صغيرًا لاستقبال الرسائل
/// الواردة، ويفتح اتصالًا مباشرًا مؤقتًا عند الإرسال.
///
/// بروتوكول بسيط: رسائل JSON مفصولة بسطر جديد (newline-delimited JSON).
class MessagingSocketService {
  MessagingSocketService({this.preferredPort = 45602});

  final int preferredPort;
  ServerSocket? _server;
  int? _boundPort;

  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();

  /// رسائل واردة من أجهزة أخرى (نوعها 'message').
  Stream<Map<String, dynamic>> get incoming => _incomingController.stream;

  int get boundPort => _boundPort ?? preferredPort;
  bool get isActive => _server != null;
  String? lastError;

  /// يبدأ خادم الاستقبال. يحاول أولًا المنفذ الثابت [preferredPort] حتى
  /// يكون معروفًا مسبقًا على كل الأجهزة — هذا ما يجعل "الاتصال بعنوان IP
  /// مباشرة يدويًا" ممكنًا حتى لو فشل اكتشاف الأجهزة تلقائيًا بالكامل (مثل
  /// شبكات تعزل الأجهزة عن بعضها في البث لكن تسمح باتصال مباشر). إن كان
  /// المنفذ الثابت محجوزًا (مثلًا تطبيق آخر يستخدمه على نفس الجهاز)، يتراجع
  /// لمنفذ عشوائي متاح حتى لا يمنع ذلك التطبيق من العمل عبر الاكتشاف التلقائي.
  ///
  /// لا يرمي استثناءً عند الفشل الكامل، بل يسجّله في [lastError] ويعيد -1
  /// حتى تستطيع شاشة الفحص عرض المشكلة وإعادة المحاولة.
  Future<int> startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, preferredPort);
    } catch (_) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (error) {
        lastError = 'تعذر تفعيل استقبال الرسائل: $error';
        return -1;
      }
    }
    _boundPort = _server!.port;
    // onError إجباري هنا أيضًا: أي خطأ يصل عبر تيار خادم الاستقبال دون
    // معالج صريح يهرب كخطأ Zone غير مُلتقَط بالكامل بدل أن يُسجَّل بوضوح.
    _server!.listen(_handleClient, onError: (Object error) => lastError = 'خطأ في خادم الاستقبال: $error');
    lastError = null;
    return _boundPort!;
  }

  Future<int> restart() async {
    await _server?.close();
    _server = null;
    return startServer();
  }

  void _handleClient(Socket client) {
    final buffer = StringBuffer();
    client.cast<List<int>>().transform(utf8.decoder).listen(
      (chunk) {
        buffer.write(chunk);
        _drainLines(buffer, client);
      },
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  void _drainLines(StringBuffer buffer, Socket client) {
    var content = buffer.toString();
    var newlineIndex = content.indexOf('\n');
    while (newlineIndex != -1) {
      final line = content.substring(0, newlineIndex).trim();
      content = content.substring(newlineIndex + 1);
      if (line.isNotEmpty) _handleLine(line, client);
      newlineIndex = content.indexOf('\n');
    }
    buffer
      ..clear()
      ..write(content);
  }

  void _handleLine(String line, Socket client) {
    Map<String, dynamic> map;
    try {
      map = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // 'message' لرسالة جديدة، 'edit_message'/'delete_message' لعمليات
    // تحرير/حذف على رسالة موجودة مسبقًا — الثلاثة تُقَرّ بنفس الآلية
    // (ack بمعرّف الحمولة) وتُمرَّر لـAppState الذي يفرّق بينها فعليًا.
    const knownTypes = {'message', 'edit_message', 'delete_message'};
    if (knownTypes.contains(map['type'])) {
      _incomingController.add(map);
      final ack = jsonEncode({'type': 'ack', 'id': map['id']});
      client.write('$ack\n');
    }
  }

  /// يحاول تسليم رسالة مباشرة لعنوان الطرف الآخر، وينتظر إقرارًا (ack).
  /// يعيد true عند التسليم الفعلي، أو false إذا تعذّر الوصول (يبقى الطرف
  /// المستدعي مسؤولًا عن إبقاء الرسالة في قائمة الانتظار لإعادة المحاولة).
  Future<bool> sendDirect({
    required InternetAddress address,
    required int port,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      final completer = Completer<bool>();
      final expectedId = payload['id'];

      final sub = socket.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
        if (chunk.contains('"ack"') && chunk.contains('$expectedId')) {
          if (!completer.isCompleted) completer.complete(true);
        }
      });

      socket.write('${jsonEncode(payload)}\n');

      final result = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      await sub.cancel();
      return result;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> stop() async {
    await _server?.close();
    await _incomingController.close();
  }
}
