import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// اتصال اختياري بخادم مُرحِّل مركزي (chat.sofinet.cc) — يُستخدَم فقط
/// عندما يتعذّر الوصول المباشر (الطرف الآخر ليس على نفس الشبكة المحلية
/// ولا في مدى بلوتوث/Wi-Fi Direct). ليس بديلًا عن الاتصال المباشر، بل
/// طبقة أخيرة إضافية تحتاج إنترنت فعليًا على الجهازين.
///
/// البروتوكول: `{"to": "<internalNumber>", "payload": {...}}`، حيث
/// payload هي بالضبط نفس حمولة JSON المستخدمة في بروتوكول الشبكة المحلية
/// (type/id/senderInternalNumber/text/...) — لا تكرار لمنطق التسلسل.
///
/// نتيجة مرحلة واحدة من [RelayService.probePath] — تُعرَض في شاشة "فحص
/// الأخطاء" لتحديد موضع توقف مسار الإنترنت بدقة (DNS أم TLS أم WebSocket).
class RelayProbeStage {
  const RelayProbeStage({required this.stage, required this.ok, required this.detail});

  final String stage;
  final bool ok;
  final String detail;
}

class RelayService {
  RelayService({this.host = 'chat.sofinet.cc', this.port, this.secure = true});

  final String host;

  /// للاختبارات فقط: منفذ مخصَّص وبروتوكول غير مشفَّر (ws/http) لخادم محلي
  /// على loopback — الإنتاج يستخدم القيم الافتراضية (wss/443) دائمًا.
  final int? port;
  final bool secure;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  String? _currentInternalNumber;
  bool _disposed = false;

  /// عدّاد محاولات إعادة الاتصال المتتالية الفاشلة — يقود backoff التصاعدي
  /// (يُصفَّر عند أول اتصال ناجح)، ويمنع [_connecting] تداخل محاولتين (مثلًا
  /// مؤقّت backoff وensureConnected من مسار إرسال فاشل في نفس اللحظة).
  int _reconnectAttempts = 0;
  bool _connecting = false;

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
            secure
                ? Uri.https(host, '/api/register')
                : Uri(scheme: 'http', host: host, port: port, path: '/api/register'),
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
    if (_disposed || _connecting || _currentInternalNumber == null) return;
    _connecting = true;
    try {
      // مرحلة DNS صريحة أولًا — تميّز في lastError بين "لا إنترنت/DNS معطوب
      // على هذه الشبكة" (شائع على بيانات جوال ضعيفة) وبين فشل الوصول للخادم
      // نفسه رغم نجاح الحلّ، وهذا التمييز هو ما يحدد أين يتوقف المسار فعليًا.
      try {
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 6));
      } catch (error) {
        lastError = 'فشل حلّ اسم المُرحِّل (DNS): $error';
        _connected = false;
        _scheduleReconnect();
        return;
      }

      final uri = Uri(
        scheme: secure ? 'wss' : 'ws',
        host: host,
        port: port,
        path: '/ws',
        queryParameters: {'internalNumber': _currentInternalNumber},
      );
      // pingInterval حرِج لسببين: (1) يكشف المقبس "الميّت بصمت" بعد تبديل
      // الشبكة (Wi-Fi↔بيانات جوال) حيث لا يصل أي خطأ TCP رغم موت المسار،
      // فينطلق onError/onDone وتبدأ إعادة الاتصال بدل بقاء التطبيق متظاهرًا
      // بالاتصال. (2) يُبقي النشاط الدوري على الاتصال فتظل خريطة NAT حية —
      // خرائط CGNAT على بيانات الجوال تُنتهَك سريعًا عند الخمول، وحينها لا
      // تصلنا الرسائل/المكالمات الواردة رغم أن "الإنترنت يعمل" في التطبيقات
      // الأخرى (هذا بالضبط عرَض "يعمل كل شيء إلا تطبيقنا" على بيانات جوال).
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 15),
      );
      await channel.ready;
      _channel = channel;
      _connected = true;
      _reconnectAttempts = 0;
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
    } finally {
      _connecting = false;
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
    // backoff تصاعدي (2ث، 4ث، 8ث... بحد أقصى 30ث) بدل حلقة ثابتة عدوانية:
    // على شبكة مقطوعة تمامًا لا فائدة من قصف الخادم كل 5 ثوانٍ، وعلى شبكة
    // متذبذبة تعود المحاولة سريعًا في البداية. يُعاد تصفيره عند أول نجاح.
    final seconds = (2 << _reconnectAttempts).clamp(2, 30);
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: seconds), _connectOnce);
  }

  /// يبدأ إعادة اتصال فورية إن كنّا غير متصلين — يُستدعى من مسار إعادة
  /// إرسال الطابور ومن عودة التطبيق للمقدمة، حتى لا يبقى التطبيق "غير متصل"
  /// منتظرًا مؤقّت backoff طويلًا رغم عودة الإنترنت فعليًا (أو بعد تبديل
  /// الشبكة). آمن للاستدعاء المتكرر: محاولة جارية أو اتصال قائم يجعلانه
  /// لا-عملية.
  void ensureConnected() {
    if (_disposed || _connected || _connecting || _currentInternalNumber == null) return;
    _reconnectTimer?.cancel();
    unawaited(_connectOnce());
  }

  /// يرسل حمولة لرقم داخلي معيَّن عبر المُرحِّل. يعيد true إذا قُبِلت
  /// الحمولة للإرسال عبر القناة (الخادم نفسه يخزّنها دائمًا بغض النظر عن
  /// كون المستلم متصلًا الآن أم لا)، أو false إن لم نكن متصلين بالمُرحِّل
  /// أصلًا الآن.
  Future<bool> send({required String to, required Map<String, dynamic> payload}) async {
    final channel = _channel;
    if (!_connected || channel == null) {
      // فشل إرسال بسبب انقطاع = إشارة لإعادة الاتصال فورًا بدل انتظار
      // backoff — الرسالة نفسها يعيدها الطابور الدائم بعد ثوانٍ على أي حال.
      ensureConnected();
      return false;
    }
    try {
      channel.sink.add(jsonEncode({'to': to, 'payload': payload}));
      return true;
    } catch (error) {
      lastError = 'تعذّر الإرسال عبر المُرحِّل: $error';
      return false;
    }
  }

  /// فحص مرحلي لمسار الإنترنت إلى المُرحِّل لشاشة "فحص الأخطاء" — يجاوب
  /// بدقة "أين يتوقف المسار؟" على أي شبكة (Wi-Fi/بيانات جوال): حلّ DNS
  /// (مع عرض عناوين IPv4/IPv6 الناتجة)، ثم طلب HTTPS فعلي للخادم، ثم حالة
  /// قناة WebSocket الحيّة. كل مرحلة تُقاس مدتها وتُسجَّل نتيجتها بشكل
  /// مستقل، ففشل DNS مع نجاح HTTPS مثلًا (أو العكس) يكشف مشاكل DNS/
  /// IPv6/CGNAT التي لا يظهرها فحص "متصل/غير متصل" الساذج.
  Future<List<RelayProbeStage>> probePath() async {
    final stages = <RelayProbeStage>[];

    final dnsStopwatch = Stopwatch()..start();
    try {
      final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 6));
      dnsStopwatch.stop();
      final v4 = addresses.where((a) => a.type == InternetAddressType.IPv4).length;
      final v6 = addresses.where((a) => a.type == InternetAddressType.IPv6).length;
      stages.add(RelayProbeStage(
        stage: 'حلّ اسم الخادم (DNS)',
        ok: addresses.isNotEmpty,
        detail: addresses.isEmpty
            ? 'لم يُرجِع DNS أي عنوان'
            : '${addresses.length} عنوان (IPv4: $v4، IPv6: $v6) في ${dnsStopwatch.elapsedMilliseconds}ms',
      ));
      if (addresses.isEmpty) return stages;
    } catch (error) {
      dnsStopwatch.stop();
      stages.add(RelayProbeStage(
        stage: 'حلّ اسم الخادم (DNS)',
        ok: false,
        detail: 'فشل بعد ${dnsStopwatch.elapsedMilliseconds}ms: $error — لا إنترنت فعلي على '
            'هذه الشبكة، أو DNS معطوب/محجوب عليها',
      ));
      return stages;
    }

    final httpStopwatch = Stopwatch()..start();
    try {
      final response = await http
          .post(Uri.https(host, '/api/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'internalNumber': 'LC-PROBE', 'displayName': 'probe'}))
          .timeout(const Duration(seconds: 8));
      httpStopwatch.stop();
      // أي استجابة HTTP (حتى 4xx) تثبت وصولًا كاملًا للخادم عبر TLS.
      stages.add(RelayProbeStage(
        stage: 'الوصول للخادم عبر HTTPS/TLS',
        ok: true,
        detail: 'استجابة ${response.statusCode} في ${httpStopwatch.elapsedMilliseconds}ms',
      ));
    } catch (error) {
      httpStopwatch.stop();
      stages.add(RelayProbeStage(
        stage: 'الوصول للخادم عبر HTTPS/TLS',
        ok: false,
        detail: 'فشل بعد ${httpStopwatch.elapsedMilliseconds}ms: $error — الخادم غير '
            'متاح، أو TLS/المنفذ 443 محجوب على هذه الشبكة',
      ));
      return stages;
    }

    stages.add(RelayProbeStage(
      stage: 'قناة WebSocket الحيّة (المراسلة الفورية)',
      ok: _connected,
      detail: _connected
          ? 'متصلة — الرسائل والإشارات تمر عبر المُرحِّل عند الحاجة'
          : 'غير متصلة حاليًا (${lastError ?? "لم تُحاوَل بعد"}) — يُعاد الاتصال تلقائيًا',
    ));
    return stages;
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _incomingController.close();
  }
}
