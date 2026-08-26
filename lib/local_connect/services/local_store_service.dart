import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

/// طبقة تخزين محلية بسيطة فوق Hive: كل صندوق (box) يخزّن قيمًا كنصوص JSON.
/// هذا يتجنب الحاجة لمولّدات أكواد (code generation) ويبقي النماذج بسيطة.
///
/// [instanceId] يُستخدم كبادئة لأسماء الصناديق فقط (وليس كمسار تخزين منفصل)
/// لأن Hive يحتفظ بسجل صناديق عام واحد لكل عملية Dart تشغيل — تشغيل أكثر
/// من [LocalConnectAppState] بنفس اسم الصندوق داخل نفس العملية (كما في
/// اختبارات التكامل التي تحاكي جهازين) يتسبب بتصادمهما على نفس الصندوق.
class LocalStoreService {
  LocalStoreService({this.instanceId = 'default'});

  final String instanceId;

  static const messagesBoxPrefix = 'messages_';

  late Box<String> identityBox;
  late Box<String> contactsBox;
  late Box<String> conversationsBox;
  late Box<String> blockedBox;
  late Box<String> statusBox;
  late Box<String> communityBox;
  final Map<String, Box<String>> _messageBoxes = {};

  String get _identityBoxName => '${instanceId}_identity';
  String get _contactsBoxName => '${instanceId}_contacts';
  String get _conversationsBoxName => '${instanceId}_conversations';
  String get _blockedBoxName => '${instanceId}_blocked';
  String get _statusBoxName => '${instanceId}_status';
  String get _communityBoxName => '${instanceId}_community';

  Future<void> init() async {
    await Hive.initFlutter('local_connect');
    identityBox = await Hive.openBox<String>(_identityBoxName);
    contactsBox = await Hive.openBox<String>(_contactsBoxName);
    conversationsBox = await Hive.openBox<String>(_conversationsBoxName);
    blockedBox = await Hive.openBox<String>(_blockedBoxName);
    statusBox = await Hive.openBox<String>(_statusBoxName);
    communityBox = await Hive.openBox<String>(_communityBoxName);
  }

  Future<Box<String>> messagesBoxFor(String conversationId) async {
    final existing = _messageBoxes[conversationId];
    if (existing != null) return existing;
    final box = await Hive.openBox<String>('$instanceId$messagesBoxPrefix$conversationId');
    _messageBoxes[conversationId] = box;
    return box;
  }

  Map<String, dynamic> decode(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;

  String encode(Map<String, dynamic> map) => jsonEncode(map);
}
