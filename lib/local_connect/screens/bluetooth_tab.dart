import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../services/app_state.dart';
import '../services/bluetooth_transport_service.dart';
import 'chat_screen.dart';

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
    // جهة اتصال معروفة مسبقًا بنفس عنوان البلوتوث — لا داعي لإعادة تبادل
    // الهوية، ننتقل مباشرة لمحادثتها القائمة.
    final existing = widget.appState.contacts.where((c) => c.bluetoothAddress == device.address);
    if (existing.isNotEmpty) {
      final conversationId =
          Conversation.idFor(widget.appState.identity.internalNumber, existing.first.internalNumber);
      final conversationMatches = widget.appState.conversations.where((c) => c.id == conversationId);
      if (conversationMatches.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversationMatches.first)),
        );
        return;
      }
    }

    setState(() => _connecting.add(device.address));
    final ok = await widget.appState.connectBluetoothDevice(device.address);

    if (!ok) {
      if (!mounted) return;
      setState(() => _connecting.remove(device.address));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر الاتصال بـ ${device.name}')));
      return;
    }

    // اتصلنا بنجاح وأرسلنا بطاقة هويتنا، لكن جهة الاتصال والمحادثة تُنشآن
    // تلقائيًا فقط بعد وصول ردّ الطرف الآخر ببطاقة هويته هو (انظر
    // AppState._handleBluetoothHello) — ننتظرها قليلًا قبل الانتقال مباشرة
    // لشاشة المحادثة، بدل ترك المستخدم يبحث عنها يدويًا في تبويب آخر.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final matches = widget.appState.contacts.where((c) => c.bluetoothAddress == device.address);
      if (matches.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    if (!mounted) return;
    setState(() => _connecting.remove(device.address));

    final matches = widget.appState.contacts.where((c) => c.bluetoothAddress == device.address);
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('اتصلنا بـ ${device.name}، بانتظار ردّه — تحقّق من تبويب "المحادثات" بعد قليل')),
      );
      return;
    }

    final contact = matches.first;
    final conversationId = Conversation.idFor(widget.appState.identity.internalNumber, contact.internalNumber);
    final conversationMatches = widget.appState.conversations.where((c) => c.id == conversationId);
    if (conversationMatches.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversationMatches.first)),
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
        final alreadyContact =
            widget.appState.contacts.any((c) => c.bluetoothAddress == device.address);
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.bluetooth)),
          title: Text(device.name),
          subtitle: Text(device.address),
          trailing: connecting
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : alreadyContact
                  ? const Icon(Icons.chat_bubble, size: 20)
                  : const Icon(Icons.person_add, size: 20),
          onTap: connecting ? null : () => _connect(device),
        );
      },
    );
  }
}
