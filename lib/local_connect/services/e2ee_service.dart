import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../utils/text_sanitize.dart';
import 'local_store_service.dart';

/// تشفير الرسائل من طرف لطرف (End-to-End) عبر تبادل مفاتيح X25519 وتشفير
/// متماثل ChaCha20-Poly1305.
///
/// كل جهاز يولّد زوج مفاتيح ثابتًا مرة واحدة عند أول تشغيل ويحتفظ به محليًا؛
/// المفتاح الخاص لا يغادر الجهاز إطلاقًا ولا يُرسَل عبر الشبكة أبدًا.
///
/// **تصميم عملي لا مثالي**: مفتاح متماثل واحد مُشتَقّ من تبادل X25519 أوّلي
/// يُستخدَم لكل الرسائل بين نفس الطرفين — لا تدوير مفاتيح لكل رسالة كحال
/// Double Ratchet في Signal Protocol الكامل. هذا أبسط بكثير للتنفيذ
/// والتحقق، ويوفّر سرّية المحتوى الفعلية (لا يقدر أي طرف وسيط — بما فيه
/// خادم الترحيل المركزي — قراءة النص أو المرفقات)، لكن بلا "سرّية تقدمية"
/// مثالية لو سُرِّب مفتاح جهاز لاحقًا. تحسين حقيقي وكبير عن الوضع السابق
/// (بلا أي تشفير على مستوى التطبيق إطلاقًا)، وليس ادّعاءً بمطابقة Signal.
///
/// **تبادل المفاتيح**: كل حمولة صادرة تحمل مفتاحنا العام (senderPublicKey)،
/// وأي حمولة واردة تُسجِّل مفتاح مُرسِلها تلقائيًا قبل معالجتها — أي أول
/// رسالة بين طرفين تصل بلا تشفير (المفتاح غير معروف بعد)، وكل ما بعدها
/// مشفَّر تلقائيًا في الاتجاهين. هذا "ثقة عند أول اتصال" (Trust On First
/// Use)، وهو النمط نفسه المستخدم فعليًا في SSH وتطبيقات أخرى كثيرة.
class E2eeService {
  E2eeService(this._store);

  final LocalStoreService _store;
  static final _algorithm = X25519();
  static final _cipher = Chacha20.poly1305Aead();

  static const _privateKeyStoreKey = 'e2ee_private_key';
  static const _publicKeyStoreKey = 'e2ee_public_key';
  static const _peerKeyPrefix = 'e2ee_peer_pubkey_';

  late SimpleKeyPair _keyPair;
  late String publicKeyBase64;

  final Map<String, SimplePublicKey> _peerPublicKeys = {};
  final Map<String, SecretKey> _sharedKeyCache = {};

  Future<void> init() async {
    final storedPrivate = _store.identityBox.get(_privateKeyStoreKey);
    final storedPublic = _store.identityBox.get(_publicKeyStoreKey);
    if (storedPrivate != null && storedPublic != null) {
      final privateBytes = base64Decode(storedPrivate);
      final publicBytes = base64Decode(storedPublic);
      _keyPair = SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      publicKeyBase64 = storedPublic;
    } else {
      _keyPair = await _algorithm.newKeyPair();
      final publicKey = await _keyPair.extractPublicKey();
      final privateBytes = await _keyPair.extractPrivateKeyBytes();
      publicKeyBase64 = base64Encode(publicKey.bytes);
      await _store.identityBox.put(_privateKeyStoreKey, base64Encode(privateBytes));
      await _store.identityBox.put(_publicKeyStoreKey, publicKeyBase64);
    }

    // استرجاع مفاتيح الأطراف الأخرى المحفوظة من جلسات سابقة، حتى لا نبدأ
    // من الصفر (رسالة أولى بلا تشفير) مع كل طرف بعد كل إعادة تشغيل للتطبيق.
    for (final key in _store.identityBox.keys.toList()) {
      if (key is String && key.startsWith(_peerKeyPrefix)) {
        final value = _store.identityBox.get(key);
        if (value == null) continue;
        final internalNumber = key.substring(_peerKeyPrefix.length);
        _peerPublicKeys[internalNumber] =
            SimplePublicKey(base64Decode(value), type: KeyPairType.x25519);
      }
    }
  }

  /// يسجّل مفتاح طرف آخر — يُستدعى بأمان من مصادر غير موثوقة (حمولة رسالة
  /// واردة من أي جهاز على الشبكة)؛ لا يفعل شيئًا عند تكرار نفس القيمة، ولا
  /// يمسح ذاكرة المفتاح المشترك المؤقتة إلا إن *تغيّر* مفتاح الطرف فعليًا
  /// (مثلًا أعاد تثبيت التطبيق فحصل على زوج مفاتيح جديد).
  void registerPeerPublicKey(String internalNumber, String? publicKeyBase64Value) {
    if (publicKeyBase64Value == null || publicKeyBase64Value.isEmpty) return;
    final existing = _peerPublicKeys[internalNumber];
    if (existing != null && base64Encode(existing.bytes) == publicKeyBase64Value) return;

    late final List<int> decoded;
    try {
      decoded = base64Decode(publicKeyBase64Value);
    } catch (_) {
      return; // مفتاح مشوَّه من طرف غير موثوق — يُتجاهَل بصمت.
    }
    _peerPublicKeys[internalNumber] = SimplePublicKey(decoded, type: KeyPairType.x25519);
    _sharedKeyCache.remove(internalNumber);
    unawaited(_store.identityBox.put('$_peerKeyPrefix$internalNumber', publicKeyBase64Value));
  }

  bool hasKeyFor(String internalNumber) => _peerPublicKeys.containsKey(internalNumber);

  Future<SecretKey> _sharedKeyFor(String internalNumber) async {
    final cached = _sharedKeyCache[internalNumber];
    if (cached != null) return cached;
    final peerPublicKey = _peerPublicKeys[internalNumber]!;
    final sharedSecret =
        await _algorithm.sharedSecretKey(keyPair: _keyPair, remotePublicKey: peerPublicKey);
    // HKDF لاشتقاق مفتاح تشفير متماثل من السر الخام الناتج عن X25519 — لا
    // يُستخدَم ناتج تبادل المفاتيح الخام كمفتاح تشفير مباشرةً أبدًا.
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode('mada-e2e-v1'),
    );
    _sharedKeyCache[internalNumber] = derived;
    return derived;
  }

  /// يشفّر [plainText] لطرف [internalNumber] — يعيد null إن لم يكن مفتاحه
  /// معروفًا بعد؛ على المُستدعي حينها إرسال النص كما هو (بلا تشفير) كحالة
  /// أولى فقط قبل تبادل المفاتيح.
  ///
  /// [plainText] قد يحمل محارف surrogate مفردة معطوبة وصلت أصلًا من مصدر
  /// خارجي غير مُنقّى (مثلًا رسالة قديمة عالقة في قائمة الانتظار قبل إضافة
  /// [sanitizeExternalText] في نقاط أخرى) — utf8.encode يرمي استثناء "string
  /// is not well-formed UTF-16" على مثل هذا النص، وبما أن هذه الدالة تُستدعى
  /// من كل محاولة إعادة إرسال لرسالة عالقة (كل 5 ثوانٍ عبر المؤقّت الدوري،
  /// وأيضًا عند كل تغيّر في قائمة الأجهزة الظاهرة)، كان استثناء غير مُلتقَط
  /// هنا يتكرر بلا توقف في سجل الأخطاء. التنقية + try/catch هنا يمنعان ذلك
  /// نهائيًا بصرف النظر عن مصدر النص المعطوب الأصلي.
  Future<String?> encryptToBase64(String internalNumber, String plainText) async {
    if (!hasKeyFor(internalNumber)) return null;
    try {
      final key = await _sharedKeyFor(internalNumber);
      final secretBox =
          await _cipher.encrypt(utf8.encode(sanitizeExternalText(plainText)), secretKey: key);
      return base64Encode(secretBox.concatenation());
    } catch (_) {
      return null;
    }
  }

  /// يفكّ تشفير حمولة من طرف [internalNumber] — يعيد null إن كان المفتاح
  /// غير معروف أو فشل فكّ التشفير لأي سبب (حمولة مشوَّهة، مفتاح غير مطابق).
  Future<String?> decryptFromBase64(String internalNumber, String cipherBase64) async {
    if (!hasKeyFor(internalNumber)) return null;
    try {
      final key = await _sharedKeyFor(internalNumber);
      final bytes = base64Decode(cipherBase64);
      final secretBox = SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16);
      final plainBytes = await _cipher.decrypt(secretBox, secretKey: key);
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }
}
