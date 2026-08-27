import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/wifi_direct_service.dart';

/// تبويب "Wi-Fi Direct": اتصال مباشر بسرعة أعلى من البلوتوث، بدون المرور
/// بالراوتر إطلاقًا. بمجرد الاتصال، اكتشاف الأجهزة والمراسلة الحاليان
/// يعملان تلقائيًا فوق الاتصال الجديد — لا حاجة لأي إجراء إضافي.
class WifiDirectTab extends StatefulWidget {
  const WifiDirectTab({super.key, required this.appState});

  final LocalConnectAppState appState;

  @override
  State<WifiDirectTab> createState() => _WifiDirectTabState();
}

class _WifiDirectTabState extends State<WifiDirectTab> with WidgetsBindingObserver {
  final Map<String, WifiDirectPeer> _peers = {};
  bool _requestingPermission = false;
  bool _permissionDenied = false;
  bool _connectedNow = false;
  String? _connectingAddress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.appState.wifiDirect.peersStream.listen((peers) {
      if (!mounted) return;
      setState(() {
        _peers
          ..clear()
          ..addEntries(peers.map((p) => MapEntry(p.deviceAddress, p)));
      });
    });
    widget.appState.wifiDirect.connectionStream.listen((info) {
      if (!mounted) return;
      setState(() {
        _connectedNow = info.isConnected;
        if (info.isConnected) _connectingAddress = null;
      });
    });
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // المستخدم قد يفتح إعدادات النظام (تفعيل Wi-Fi، منح صلاحية موقع...)
    // ويعود لهذه الشاشة دون أن تُعاد فتحها من الصفر — initState لا يُستدعى
    // مرة أخرى، فتبقى حالة الصلاحية/الاكتشاف القديمة معروضة رغم تغيّرها
    // فعليًا. إعادة _start عند العودة تتحقق من كل شيء من جديد.
    if (state == AppLifecycleState.resumed) _start();
  }

  Future<void> _start() async {
    setState(() => _requestingPermission = true);
    final granted = await widget.appState.requestWifiDirectPermissions();
    if (!mounted) return;
    setState(() {
      _requestingPermission = false;
      _permissionDenied = !granted;
    });
    if (granted) await widget.appState.wifiDirect.startDiscovery();
  }

  Future<void> _connect(WifiDirectPeer peer) async {
    setState(() => _connectingAddress = peer.deviceAddress);
    final requested = await widget.appState.wifiDirect.connect(peer.deviceAddress);
    if (!requested && mounted) {
      setState(() => _connectingAddress = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر بدء الاتصال بـ ${peer.deviceName}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_requestingPermission) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('يحتاج Wi-Fi Direct صلاحية الأجهزة القريبة لعرض الأجهزة والاتصال بها.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _start, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      );
    }

    final peers = _peers.values.toList();

    return Column(
      children: [
        if (_connectedNow)
          Container(
            width: double.infinity,
            color: Colors.green.shade50,
            padding: const EdgeInsets.all(12),
            child: const Text(
              '✓ متصل عبر Wi-Fi Direct — سيظهر الجهاز الآخر تلقائيًا في "أجهزة قريبة" خلال لحظات',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.green),
            ),
          ),
        Expanded(
          child: peers.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لا توجد أجهزة Wi-Fi Direct ظاهرة حاليًا.\nتأكد أن Wi-Fi مفعّل على الجهازين.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    final connecting = _connectingAddress == peer.deviceAddress;
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.wifi)),
                      title: Text(peer.deviceName),
                      subtitle: Text(peer.deviceAddress),
                      trailing: connecting
                          ? const SizedBox(
                              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: connecting ? null : () => _connect(peer),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
