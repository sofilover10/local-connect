import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// نتيجة مسبار شبكة واحد (STUN/TURN) — مع RTT المُقاس فعليًا، وتفاصيل مثل
/// العنوان العام المُكتشَف (من STUN) الذي يكشف نوع NAT عمليًا.
class NetProbeResult {
  const NetProbeResult({required this.ok, required this.detail, this.rttMs});

  final bool ok;
  final String detail;
  final int? rttMs;
}

/// مسابير شبكة فعلية على مستوى البروتوكول — لا تعتمد على حالة "متصل" التي
/// يبلّغها النظام (تكذب أحيانًا على بيانات الجوال)، بل تُثبت الوصول بحزم
/// حقيقية:
///
/// - **STUN binding request** (RFC 5389): رسالة 20 بايت عبر UDP، والرد يحمل
///   XOR-MAPPED-ADDRESS — أي عنواننا العام كما يراه الإنترنت. نجاحها يثبت أن
///   UDP يعمل وأن NAT يسمح بالاتصالات الصادرة (الأساس الذي يقوم عليه WebRTC
///   المباشر). فشلها على بيانات الجوال يعني غالبًا UDP محجوب/مقيَّد.
/// - **TURN TCP/TLS**: مجرد نجاح المصافحة على 443 يثبت أن مسار الترحيل
///   الأخير (الذي تلجأ إليه المكالمات خلف CGNAT) قابل للوصول من هذه الشبكة.
///
/// هذه المسابير "وصول فقط" — لا تُنشئ TURN allocation حقيقية (ذلك يتطلب
/// تبادل اعتمادات كاملًا). الدليل القاطع على عمل TURN ترحيلًا يبقى ظهور
/// مرشّح relay في سجل المكالمة الفعلي (انظر CallService).
class NetProbeService {
  static final _random = Random();

  /// مسبار STUN binding — يعيد العنوان العام المُكتشَف وRTT عند النجاح.
  Future<NetProbeResult> stunProbe(String host, int port,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final stopwatch = Stopwatch()..start();
    RawDatagramSocket? socket;
    try {
      final addresses = await InternetAddress.lookup(host).timeout(timeout);
      if (addresses.isEmpty) {
        return const NetProbeResult(ok: false, detail: 'DNS لم يُرجِع أي عنوان');
      }
      final target = addresses.first;

      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // طلب STUN Binding: type=0x0001، طول=0، magic cookie، ثم 12 بايت
      // معرّف معاملة عشوائي (يجب أن يعود مطابقًا في الرد).
      final transactionId = Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256)));
      final request = Uint8List(20);
      final view = ByteData.view(request.buffer);
      view.setUint16(0, 0x0001);
      view.setUint16(2, 0);
      view.setUint32(4, 0x2112A442);
      request.setRange(8, 20, transactionId);
      socket.send(request, target, port);

      // يجب استدعاء receive() من داخل معالج حدث read مباشرة — استدعاؤه بعد
      // اكتمال firstWhere (الذي يلغي الاشتراك) يُسقِط الحزمة المعلَّقة ويعيد
      // null رغم وصولها فعليًا (سلوك موثَّق عمليًا لـRawDatagramSocket).
      final completer = Completer<List<int>?>();
      final subscription = socket.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket!.receive();
            if (datagram != null && !completer.isCompleted) completer.complete(datagram.data);
          }
        },
        // ويندوز يرفع SocketException (ICMP port-unreachable) على منفذ مغلق
        // بدل الصمت — يُعامَل كـ"لا ردّ" أيضًا.
        onError: (_) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      final List<int>? response;
      try {
        response = await completer.future.timeout(timeout, onTimeout: () => null);
      } finally {
        await subscription.cancel();
      }
      stopwatch.stop();
      if (response == null) {
        return NetProbeResult(
          ok: false,
          detail: 'لا ردّ خلال ${timeout.inSeconds} ثوانٍ — UDP محجوب أو مقيَّد على هذه الشبكة '
              '(شائع على بعض شبكات الجوال؛ المكالمات ستحتاج TURN عبر TCP/443)',
        );
      }
      if (response.length < 20) {
        return const NetProbeResult(ok: false, detail: 'رد غير صالح من خادم STUN');
      }
      final responseView = ByteData.view(Uint8List.fromList(response).buffer);
      final type = responseView.getUint16(0);
      final cookie = responseView.getUint32(4);
      final sameTransaction = _listEquals(response.sublist(8, 20), transactionId);
      if (type != 0x0101 || cookie != 0x2112A442 || !sameTransaction) {
        return const NetProbeResult(ok: false, detail: 'رد STUN غير مطابق للطلب');
      }
      final mapped = _parseXorMappedAddress(response, transactionId);
      return NetProbeResult(
        ok: true,
        rttMs: stopwatch.elapsedMilliseconds,
        detail: mapped == null
            ? 'STUN يعمل (RTT ${stopwatch.elapsedMilliseconds}ms)'
            : 'عنوانك العام: $mapped (RTT ${stopwatch.elapsedMilliseconds}ms)',
      );
    } on TimeoutException {
      return NetProbeResult(
        ok: false,
        detail: 'لا ردّ خلال ${timeout.inSeconds} ثوانٍ — UDP محجوب أو مقيَّد على هذه الشبكة '
            '(شائع على بعض شبكات الجوال؛ المكالمات ستحتاج TURN عبر TCP/443)',
      );
    } catch (error) {
      return NetProbeResult(ok: false, detail: 'فشل المسبار: $error');
    } finally {
      socket?.close();
    }
  }

  /// مسبار TURN عبر UDP (STUN binding إلى منفذ خادم TURN — coturn وأمثاله
  /// يردّون على binding requests بلا اعتمادات، فيثبت أن مسار UDP للخادم حيّ).
  Future<NetProbeResult> turnUdpProbe(String host, int port,
          {Duration timeout = const Duration(seconds: 4)}) =>
      stunProbe(host, port, timeout: timeout);

  /// مسبار TURN عبر TCP — نجاح الاتصال يثبت وصول المسار البديل المستخدم عند
  /// حجب UDP.
  Future<NetProbeResult> turnTcpProbe(String host, int port,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      await socket.close();
      return NetProbeResult(
          ok: true, rttMs: stopwatch.elapsedMilliseconds, detail: 'TCP $port متاح (RTT ${stopwatch.elapsedMilliseconds}ms)');
    } catch (error) {
      return NetProbeResult(ok: false, detail: 'TCP $port غير متاح: $error');
    }
  }

  /// مسبار TURN عبر TLS على 443 — أهم مسار أخير لأنه يمرّ عبر تقريبًا كل
  /// جدار حماية/شبكة جوال (يبدو كأي HTTPS عادي).
  Future<NetProbeResult> turnTlsProbe(String host, int port,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await SecureSocket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      final cert = socket.peerCertificate;
      await socket.close();
      return NetProbeResult(
        ok: true,
        rttMs: stopwatch.elapsedMilliseconds,
        detail: 'TLS على $port يعمل (RTT ${stopwatch.elapsedMilliseconds}ms'
            '${cert == null ? '' : '، شهادة: ${cert.subject}'})',
      );
    } catch (error) {
      return NetProbeResult(ok: false, detail: 'TLS على $port فشل: $error');
    }
  }

  /// يفكّ سمة XOR-MAPPED-ADDRESS (0x0020) من رد STUN — عنواننا العام كما
  /// يراه الخادم. يدعم IPv4 فقط (يكفي للتشخيص الحالي؛ الخوادم المستخدمة v4).
  String? _parseXorMappedAddress(List<int> response, Uint8List transactionId) {
    final length = ByteData.view(Uint8List.fromList(response).buffer).getUint16(2);
    var offset = 20;
    final end = 20 + length;
    while (offset + 4 <= end && offset + 4 <= response.length) {
      final view = ByteData.view(Uint8List.fromList(response).buffer);
      final attrType = view.getUint16(offset);
      final attrLength = view.getUint16(offset + 2);
      final valueStart = offset + 4;
      if (attrType == 0x0020 && attrLength >= 8 && valueStart + attrLength <= response.length) {
        final family = response[valueStart + 1];
        if (family != 0x01) return null; // IPv6 — لا نفكّه هنا
        final port = view.getUint16(valueStart + 2) ^ 0x2112;
        final ip = [
          response[valueStart + 4] ^ 0x21,
          response[valueStart + 5] ^ 0x12,
          response[valueStart + 6] ^ 0xA4,
          response[valueStart + 7] ^ 0x42,
        ].join('.');
        return '$ip:$port';
      }
      offset = valueStart + attrLength + ((4 - attrLength % 4) % 4);
    }
    return null;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
