import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:permission_handler/permission_handler.dart';

import '../models/contact.dart';

/// يحفظ جهة اتصال من LocalConnect في دفتر جهات اتصال الهاتف الفعلي (نفس
/// التطبيق الذي يفتحه المستخدم من طلبات الاتصال العادية)، بحيث لا يبقى
/// الرقم الداخلي حبيسًا داخل تطبيقنا فقط.
///
/// مسمّى بالاستيراد `fc` لأن حزمة flutter_contacts تُعرِّف صنفًا اسمه أيضًا
/// Contact، ويتعارض مع نموذج Contact الخاص بهذا التطبيق.
class PhoneContactsService {
  /// يطلب صلاحية الوصول لجهات الاتصال إن لم تُمنَح بعد. يعيد true إن كانت
  /// ممنوحة (سواء سابقًا أو للتو).
  Future<bool> requestPermission() async {
    final status = await Permission.contacts.status;
    if (status.isGranted) return true;
    final result = await Permission.contacts.request();
    return result.isGranted;
  }

  /// يحفظ [contact] كجهة اتصال جديدة في الهاتف. يضيف الرقم الداخلي دائمًا
  /// (بتصنيف مخصَّص "LocalConnect")، ورقم الهاتف الحقيقي أيضًا إن توفر.
  /// يرمي استثناءً إن رُفضت الصلاحية — على الطرف المستدعي عرض رسالة مناسبة.
  Future<void> saveToPhoneContacts(Contact contact) async {
    final granted = await requestPermission();
    if (!granted) {
      throw StateError('لم تُمنح صلاحية الوصول لجهات الاتصال');
    }

    final phones = <fc.Phone>[
      fc.Phone(contact.internalNumber, label: fc.PhoneLabel.custom, customLabel: 'LocalConnect'),
      if (contact.phoneNumber != null && contact.phoneNumber!.isNotEmpty)
        fc.Phone(contact.phoneNumber!, label: fc.PhoneLabel.mobile),
    ];

    final phoneContact = fc.Contact()
      ..name.first = contact.displayName
      ..phones = phones;

    await phoneContact.insert();
  }
}
