import 'dart:io';

/// حالة لحظية (غير مخزَّنة) لجهاز آخر ظاهر حاليًا على الشبكة المحلية.
class PeerInfo {
  PeerInfo({
    required this.internalNumber,
    required this.displayName,
    required this.address,
    required this.tcpPort,
    required this.lastSeen,
    this.phoneNumber,
  });

  final String internalNumber;
  final String displayName;
  final InternetAddress address;
  final int tcpPort;
  DateTime lastSeen;

  /// رقم هاتف الطرف الآخر إن شاركه ضمن بطاقة حضوره (اختياري من طرفه).
  final String? phoneNumber;

  bool isStaleAt(DateTime now, Duration timeout) =>
      now.difference(lastSeen) > timeout;
}
