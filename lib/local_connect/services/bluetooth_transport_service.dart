import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/text_sanitize.dart';

class BluetoothDeviceInfo {
  BluetoothDeviceInfo({required this.name, required this.address});

  final String name;
  final String address;
}

/// غلاف Dart فوق قناة المنصّة الأصلية (Kotlin) لبلوتوث كلاسيكي (RFCOMM).
/// يوفّر اكتشافًا للأجهزة القريبة، اتصالًا صادرًا، وإرسال/استقبال بايتات
/// خامة على اتصال قائم. هذا النقل فقط — تأطير رسائل JSON فوقه مسؤولية
/// [BluetoothMessagingService].
class BluetoothTransportService {
  static const _method = MethodChannel('local_connect/bluetooth');
  static const _devicesChannel = EventChannel('local_connect/bluetooth/devices');
  static const _dataChannel = EventChannel('local_connect/bluetooth/data');

  Stream<BluetoothDeviceInfo>? _devicesStream;
  Stream<Map<String, dynamic>>? _dataStream;

  Stream<BluetoothDeviceInfo> get devicesStream => _devicesStream ??=
      _devicesChannel.receiveBroadcastStream().map((event) {
        final m = event as Map<dynamic, dynamic>;
        return BluetoothDeviceInfo(
          name: sanitizeExternalText(m['name'] as String),
          address: m['address'] as String,
        );
      });

  /// أحداث بيانات خامة: `{'address', 'bytes'}` عند استقبال بايتات،
  /// `{'address', 'connected': true}` عند نجاح اتصال (صادر أو وارد)،
  /// أو `{'address', 'disconnected': true}` عند انقطاعه.
  Stream<Map<String, dynamic>> get dataStream =>
      _dataStream ??= _dataChannel.receiveBroadcastStream().map((event) {
        final m = event as Map<dynamic, dynamic>;
        return m.map((key, value) => MapEntry(key as String, value));
      });

  Future<bool> get isSupported async {
    if (!Platform.isAndroid) return false;
    try {
      return await _method.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> get isEnabled async {
    try {
      return await _method.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// يُستدعى بعد منح صلاحية البلوتوث من واجهة Flutter — خادم الاستقبال
  /// الأصلي يحاول التفعيل مرة واحدة فقط عند إقلاع التطبيق (قبل أن تُمنح أي
  /// صلاحية)، فيفشل بصمت إن لم تكن ممنوحة بعد؛ هذا يعيد محاولة تفعيله
  /// فعليًا الآن بعد أن باتت الصلاحية متوفرة.
  Future<void> restartServer() async {
    try {
      await _method.invokeMethod('restartServer');
    } on PlatformException {
      // لا شيء يُفعَل — سيبقى البلوتوث معطّلًا وتظهر مشكلته في شاشة الفحص.
    }
  }

  Future<bool> startDiscovery() async {
    try {
      return await _method.invokeMethod<bool>('startDiscovery') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopDiscovery() async {
    try {
      return await _method.invokeMethod<bool>('stopDiscovery') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> connect(String address) async {
    try {
      return await _method.invokeMethod<bool>('connect', {'address': address}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> send(String address, Uint8List bytes) async {
    try {
      return await _method.invokeMethod<bool>('send', {'address': address, 'bytes': bytes}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> disconnectDevice(String address) async {
    try {
      await _method.invokeMethod('disconnectDevice', {'address': address});
    } on PlatformException {
      // لا شيء يُفعَل — الجهاز غير متصل أصلًا على الأغلب.
    }
  }
}
