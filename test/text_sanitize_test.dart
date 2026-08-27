import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_connect/local_connect/utils/text_sanitize.dart';

void main() {
  test('يبقي النص السليم (بما فيه رموز تعبيرية مزدوجة الوحدة) كما هو', () {
    const input = 'جهاز أحمد 📱';
    expect(sanitizeExternalText(input), input);
    expect(() => utf8.encode(sanitizeExternalText(input)), returnsNormally);
  });

  test('يسقط high surrogate مفردًا بلا low surrogate تالٍ له', () {
    final corrupted = String.fromCharCodes([0x0645, 0xD83D, 0x0646]);
    final result = sanitizeExternalText(corrupted);
    expect(result, 'من');
    expect(() => utf8.encode(result), returnsNormally);
  });

  test('يسقط low surrogate مفردًا بلا high surrogate قبله', () {
    final corrupted = String.fromCharCodes([0x0645, 0xDE00, 0x0646]);
    final result = sanitizeExternalText(corrupted);
    expect(result, 'من');
    expect(() => utf8.encode(result), returnsNormally);
  });
}
