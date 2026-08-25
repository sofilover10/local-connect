import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/bluetooth_transport_service.dart';

/// تبويب "بلوتوث": اتصال مباشر بين جهازين بدون المرور بالراوتر إطلاقًا،
/// بديل يعمل حتى لو منع الراوتر بث الاكتشاف بين الأجهزة على شبكة Wi-Fi.
class BluetoothTab extends StatefulWidget {
  const BluetoothTab({super.key, required this.appState});

  final LocalConnectAppState appState;

  @override
  State<BluetoothTab> createState() => _BluetoothTabState();
}

class _BluetoothTabState extends State<BluetoothTab> {
  final Map<String, BluetoothDeviceInfo> _devices = {};
  final Set<String> _connecting = {};
  bool _requestingPermission = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    widget.appState.bluetoothTransport.devicesStream.listen((device) {
      if (!mounted) return;
      setState(() => _devices[device.address] = device);
    });
    _start();
  }

  Future<void> _start() async {
    setState(() => _requestingPermission = true);
    final granted = await widget.appState.requestBluetoothPermissions();
    if (!mounted) return;
    setState(() {
      _requestingPermission = false;
      _permissionDenied = !granted;
    });
    if (granted) {
      // خادم الاستقبال الأصلي حاول التفعيل مرة عند إقلاع التطبيق وفشل
      // بصمت لأن الصلاحية لم تُمنح بعد آنذاك — أعد المحاولة الآن فعليًا.
      await widget.appState.bluetoothTransport.restartServer();
      await widget.appState.bluetoothTransport.startDiscovery();
    }
  }

  Future<void> _connect(BluetoothDeviceInfo device) async {
    setState(() => _connecting.add(device.address));
    final ok = await widget.appState.connectBluetoothDevice(device.address);
    if (!mounted) return;
    setState(() => _connecting.remove(device.address));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'تم الاتصال بـ ${device.name} — سيظهر كجهة اتصال خلال لحظات'
              : 'تعذّر الاتصال بـ ${device.name}',
        ),
      ),
    );
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
              const Text('يحتاج البلوتوث صلاحية الجهاز القريب لعرض الأجهزة والاتصال بها.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _start, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      );
    }

    final devices = _devices.values.toList();
    if (devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'لا توجد أجهزة بلوتوث ظاهرة حاليًا.\nتأكد أن البلوتوث مفعّل على الجهازين وأنهما قريبان من بعض.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        final connecting = _connecting.contains(device.address);
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.bluetooth)),
          title: Text(device.name),
          subtitle: Text(device.address),
          trailing: connecting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: connecting ? null : () => _connect(device),
        );
      },
    );
  }
}
