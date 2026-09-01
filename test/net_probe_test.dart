import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/net_probe_service.dart';

/// يختبر مسبار STUN مقابل خادم UDP وهمي محلي يردّ بردّ binding صحيح
/// بمعيار RFC 5389 (يحمل XOR-MAPPED-ADDRESS لعنوان معروف مسبقًا) — فيتحقق
/// أن التحليل والتحقق من المعاملة والكوكي وفكّ التشفير المتبادل كلها صحيحة
/// بايتًا ببايت، دون الحاجة لإنترنت.
void main() {
  test('stunProbe ينجح مع ردّ binding صحيح ويفكّ العنوان العام ويقيس RTT', () async {
    const expectedIp = [203, 0, 113, 7];
    const expectedPort = 5678;

    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = server.receive();
      if (datagram == null || datagram.data.length < 20) return;
      final request = datagram.data;
      final transactionId = request.sublist(8, 20);

      // ردّ Binding Success: type=0x0101 + XOR-MAPPED-ADDRESS.
      final response = Uint8List(20 + 8 + 4); // ترويسة + سمة (8) مع حشوة محاذاة
      final view = ByteData.view(response.buffer);
      view.setUint16(0, 0x0101);
      view.setUint16(2, 8); // طول السمات
      view.setUint32(4, 0x2112A442);
      response.setRange(8, 20, transactionId);
      view.setUint16(20, 0x0020); // XOR-MAPPED-ADDRESS
      view.setUint16(22, 8);
      response[24] = 0;
      response[25] = 0x01; // IPv4
      view.setUint16(26, expectedPort ^ 0x2112);
      response[28] = expectedIp[0] ^ 0x21;
      response[29] = expectedIp[1] ^ 0x12;
      response[30] = expectedIp[2] ^ 0xA4;
      response[31] = expectedIp[3] ^ 0x42;

      server.send(response, datagram.address, datagram.port);
    });

    final result = await NetProbeService().stunProbe('127.0.0.1', server.port);
    expect(result.ok, isTrue, reason: result.detail);
    expect(result.rttMs, isNotNull);
    expect(result.detail, contains('203.0.113.7:5678'));
  });

  test('stunProbe يفشل بوضوح عندما لا يردّ أحد (UDP محجوب/مقيَّد)', () async {
    // منفذ مغلق على loopback بلا خادم — لا ردّ إطلاقًا.
    final result = await NetProbeService()
        .stunProbe('127.0.0.1', 9, timeout: const Duration(milliseconds: 600));
    expect(result.ok, isFalse);
    expect(result.detail, contains('لا ردّ'));
  });

  test('ردّ بمعرّف معاملة مختلف يُرفَض (لا يُقبَل ردّ زائف/تائه)', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = server.receive();
      if (datagram == null) return;
      final response = Uint8List(20);
      final view = ByteData.view(response.buffer);
      view.setUint16(0, 0x0101);
      view.setUint32(4, 0x2112A442);
      // معرّف معاملة مختلف عمدًا — يحاكي ردًا تائهًا/مزوّرًا لا يخص طلبنا.
      response.setRange(8, 20, List.filled(12, 0xAA));
      server.send(response, datagram.address, datagram.port);
    });

    final result = await NetProbeService()
        .stunProbe('127.0.0.1', server.port, timeout: const Duration(milliseconds: 600));
    expect(result.ok, isFalse);
  });
}
