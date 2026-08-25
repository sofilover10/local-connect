class Contact {
  Contact({
    required this.internalNumber,
    required this.displayName,
    this.phoneNumber,
    this.manualAddress,
    this.bluetoothAddress,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  /// المعرّف العنواني الوحيد لجهة الاتصال: رقم داخلي قصير يُستخدم للتعارف
  /// على الشبكة المحلية، سواء وُلِّد تلقائيًا أو كان رقم هاتف حقيقي.
  final String internalNumber;

  final String displayName;

  /// اختياري: رقم هاتف حقيقي إن توفر، لعرضه فقط أو المطابقة مع جهات الاتصال.
  final String? phoneNumber;

  /// عنوان IP أُدخل يدويًا (مثلًا من إعدادات Wi-Fi على جهاز الطرف الآخر).
  /// يُستخدم كخطة بديلة للإرسال عندما لا يظهر الطرف عبر الاكتشاف التلقائي
  /// (مثلًا بسبب شبكة تحجب بث UDP بين الأجهزة لكن تسمح باتصال مباشر).
  final String? manualAddress;

  /// عنوان MAC لبلوتوث الطرف الآخر، يُضبط عند الاتصال به عبر تبويب
  /// "بلوتوث" — خطة بديلة تعمل حتى لو لم يكونا على نفس شبكة Wi-Fi إطلاقًا.
  final String? bluetoothAddress;

  final DateTime addedAt;

  Map<String, dynamic> toMap() => {
        'internalNumber': internalNumber,
        'displayName': displayName,
        'phoneNumber': phoneNumber,
        'manualAddress': manualAddress,
        'bluetoothAddress': bluetoothAddress,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Contact.fromMap(Map<String, dynamic> map) => Contact(
        internalNumber: map['internalNumber'] as String,
        displayName: map['displayName'] as String,
        phoneNumber: map['phoneNumber'] as String?,
        manualAddress: map['manualAddress'] as String?,
        bluetoothAddress: map['bluetoothAddress'] as String?,
        addedAt: DateTime.parse(map['addedAt'] as String),
      );
}
