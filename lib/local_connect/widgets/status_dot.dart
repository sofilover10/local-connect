import 'package:flutter/material.dart';

/// نقطة خضراء/رمادية صغيرة تدل على ظهور الطرف الآخر حاليًا على الشبكة.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? Colors.green : Colors.grey,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }
}
