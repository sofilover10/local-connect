import 'dart:math';

import 'package:uuid/uuid.dart';

import 'local_store_service.dart';

/// هوية هذا الجهاز: معرّف داخلي ثابت + رقم داخلي قصير يسهل تبادله شفهيًا
/// أو كتابيًا بين المستخدمين دون الحاجة لرقم هاتف حقيقي.
class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.internalNumber,
    required this.displayName,
    this.phoneNumber,
  });

  final String deviceId;
  final String internalNumber;
  String displayName;

  /// رقم هاتف حقيقي اختياري يضبطه المستخدم بنفسه. إن كان معبّأً، يُرفَق
  /// تلقائيًا مع أي رسالة أو بطاقة حضور يبثّها هذا الجهاز، بحيث يحفظه أي
  /// طرف يتواصل معه دون الحاجة لعملية "طلب/موافقة" منفصلة — نفس فكرة
  /// عرض رقمك في بطاقة تعريف تشاركها بمجرد التواصل.
  String? phoneNumber;
}

class DeviceIdentityService {
  DeviceIdentityService(this._store);

  final LocalStoreService _store;
  static const _key = 'self';

  Future<DeviceIdentity> loadOrCreate({required String defaultName}) async {
    final raw = _store.identityBox.get(_key);
    if (raw != null) {
      final map = _store.decode(raw);
      return DeviceIdentity(
        deviceId: map['deviceId'] as String,
        internalNumber: map['internalNumber'] as String,
        displayName: map['displayName'] as String,
        phoneNumber: map['phoneNumber'] as String?,
      );
    }

    final identity = DeviceIdentity(
      deviceId: const Uuid().v4(),
      internalNumber: _generateInternalNumber(),
      displayName: defaultName,
    );
    await _persist(identity);
    return identity;
  }

  Future<void> updateDisplayName(DeviceIdentity identity, String name) async {
    identity.displayName = name;
    await _persist(identity);
  }

  Future<void> updatePhoneNumber(DeviceIdentity identity, String? phoneNumber) async {
    identity.phoneNumber = (phoneNumber == null || phoneNumber.trim().isEmpty) ? null : phoneNumber.trim();
    await _persist(identity);
  }

  Future<void> _persist(DeviceIdentity identity) async {
    await _store.identityBox.put(
      _key,
      _store.encode({
        'deviceId': identity.deviceId,
        'internalNumber': identity.internalNumber,
        'displayName': identity.displayName,
        'phoneNumber': identity.phoneNumber,
      }),
    );
  }

  /// رقم داخلي بصيغة LC-XXXXXX يسهل تذكره وإملاؤه.
  String _generateInternalNumber() {
    final random = Random.secure();
    final digits = List.generate(6, (_) => random.nextInt(10)).join();
    return 'LC-$digits';
  }
}
