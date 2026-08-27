import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/text_sanitize.dart';

class WifiDirectPeer {
  WifiDirectPeer({required this.deviceName, required this.deviceAddress});

  final String deviceName;
  final String deviceAddress;
}

class WifiDirectConnectionInfo {
  WifiDirectConnectionInfo({
    required this.isConnected,
    required this.isGroupOwner,
    required this.groupOwnerAddress,
  });

  final bool isConnected;
  final bool isGroupOwner;
  final String groupOwnerAddress;
}

/// يربط جهازين مباشرة عبر Wi-Fi Direct (كود Android أصلي في MainActivity)،
/// بدون المرور بالراوتر إطلاقًا — يتجاوز أي عزل أجهزة (AP Isolation) قد
/// يفعّله الراوتر. بمجرد الاتصال، اكتشاف الأجهزة والمراسلة الحاليان
/// (UDP/TCP) يعملان تلقائيًا فوق الواجهة الجديدة دون أي تغيير إضافي.
class WifiDirectService {
  static const _method = MethodChannel('local_connect/wifi_direct');
  static const _peersChannel = EventChannel('local_connect/wifi_direct/peers');
  static const _connectionChannel = EventChannel('local_connect/wifi_direct/connection');

  Stream<List<WifiDirectPeer>>? _peersStream;
  Stream<WifiDirectConnectionInfo>? _connectionStream;

  Stream<List<WifiDirectPeer>> get peersStream => _peersStream ??=
      _peersChannel.receiveBroadcastStream().map((event) {
        final list = (event as List).cast<Map<dynamic, dynamic>>();
        return list
            .map((m) => WifiDirectPeer(
                  deviceName: sanitizeExternalText(m['deviceName'] as String),
                  deviceAddress: m['deviceAddress'] as String,
                ))
            .toList();
      });

  Stream<WifiDirectConnectionInfo> get connectionStream => _connectionStream ??=
      _connectionChannel.receiveBroadcastStream().map((event) {
        final m = event as Map<dynamic, dynamic>;
        return WifiDirectConnectionInfo(
          isConnected: m['isConnected'] as bool,
          isGroupOwner: m['isGroupOwner'] as bool,
          groupOwnerAddress: m['groupOwnerAddress'] as String,
        );
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

  Future<bool> connect(String deviceAddress) async {
    try {
      return await _method.invokeMethod<bool>('connect', {'address': deviceAddress}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> disconnect() async {
    try {
      return await _method.invokeMethod<bool>('disconnect') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
