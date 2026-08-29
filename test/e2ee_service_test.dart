import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/services/e2ee_service.dart';
import 'package:local_connect/local_connect/services/local_store_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// بيئة `flutter test` لا توفر قنوات المنصّة الحقيقية، لذا نزوّد path_provider
/// بمسار مجلد مؤقت حقيقي على القرص بدل الاعتماد على قناة منصّة غير موجودة
/// (نفس النمط المستخدم في lan_messaging_integration_test.dart).
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = await Directory.systemTemp.createTemp('e2ee_test_');
    return dir.path;
  }
}

Future<LocalStoreService> _newStore(String instanceId) async {
  final store = LocalStoreService(instanceId: instanceId);
  await store.init();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  test('تبادل المفاتيح والتشفير/فك التشفير يعملان فعليًا بين طرفين', () async {
    final storeA = await _newStore('e2ee_a');
    final storeB = await _newStore('e2ee_b');
    final alice = E2eeService(storeA);
    final bob = E2eeService(storeB);
    await alice.init();
    await bob.init();

    expect(alice.hasKeyFor('bob'), isFalse);
    expect(bob.hasKeyFor('alice'), isFalse);

    // تبادل المفاتيح (كما يحدث فعليًا عبر senderPublicKey في كل حمولة صادرة).
    alice.registerPeerPublicKey('bob', bob.publicKeyBase64);
    bob.registerPeerPublicKey('alice', alice.publicKeyBase64);

    expect(alice.hasKeyFor('bob'), isTrue);

    const plainText = 'مرحبا يا بوب، هذه رسالة سرّية 🔒';
    final cipherText = await alice.encryptToBase64('bob', plainText);
    expect(cipherText, isNotNull);
    expect(cipherText, isNot(contains('مرحبا')));

    final decrypted = await bob.decryptFromBase64('alice', cipherText!);
    expect(decrypted, plainText);
  });

  test('التشفير بلا مفتاح معروف يعيد null (لا يرمي استثناءً)', () async {
    final store = await _newStore('e2ee_no_key');
    final service = E2eeService(store);
    await service.init();

    final result = await service.encryptToBase64('unknown', 'نص');
    expect(result, isNull);
  });

  test('فك التشفير بمفتاح مختلف عن المُرسِل الفعلي يفشل بأمان (null لا استثناء)', () async {
    final storeA = await _newStore('e2ee_a2');
    final storeB = await _newStore('e2ee_b2');
    final storeC = await _newStore('e2ee_c2');
    final alice = E2eeService(storeA);
    final bob = E2eeService(storeB);
    final eve = E2eeService(storeC);
    await alice.init();
    await bob.init();
    await eve.init();

    alice.registerPeerPublicKey('bob', bob.publicKeyBase64);
    bob.registerPeerPublicKey('alice', alice.publicKeyBase64);
    // بوب يظن خطأً أن مفتاح "alice" هو مفتاح Eve (محاكاة تسجيل مفتاح خاطئ).
    bob.registerPeerPublicKey('impersonator', eve.publicKeyBase64);

    final cipherText = await alice.encryptToBase64('bob', 'سرّي');
    final result = await bob.decryptFromBase64('impersonator', cipherText!);
    expect(result, isNull);
  });
}
