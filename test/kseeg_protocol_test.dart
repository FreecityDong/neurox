import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/data/devices/kseeg_protocol.dart';

void main() {
  test(
    '20 Windows SDK vectors match in compatibility mode; Android lead is tested separately',
    () {
      final vectors =
          jsonDecode(
                File('test/fixtures/kseeg_sdk_vectors.json').readAsStringSync(),
              )
              as List;
      expect(vectors, hasLength(20));
      for (final vector in vectors) {
        final hex = vector['hex'] as String;
        final bytes = Uint8List.fromList([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
        expect(
          KseegProtocol.parse(
            vector['kind'] as String,
            bytes,
            leadConvention: LeadConvention.windows,
          ),
          vector['expected'],
          reason: '${vector['kind']}: $hex',
        );
      }
    },
  );
  test('minimum lengths, unknown UUIDs and case normalization', () {
    for (final entry in KseegProtocol.minimumLengths.entries) {
      expect(
        () => KseegProtocol.parse(entry.key, Uint8List(entry.value - 1)),
        throwsFormatException,
      );
      expect(
        KseegProtocol.parse(
          KseegProtocol.uuids[entry.key]!.toUpperCase(),
          Uint8List(entry.value),
        ),
        KseegProtocol.parse(entry.key, Uint8List(entry.value)),
      );
    }
    expect(
      () => KseegProtocol.parse('unknown', Uint8List(90)),
      throwsFormatException,
    );
  });
  test('unsigned big endian scaling and lead always uses actual last byte', () {
    final b = Uint8List(70);
    b[3] = 255;
    final data = ByteData.sublistView(b);
    for (var i = 0; i < 16; i++) {
      data.setUint16(4 + i * 4, 65535);
      data.setUint16(6 + i * 4, 32768);
    }
    b[68] = 1;
    b[69] = 0;
    final p = KseegProtocol.parse('raw', b);
    expect(p['channel_1'], List.filled(16, 6.5535));
    expect(p['channel_2'], List.filled(16, 3.2768));
    expect(p['power'], 255);
    expect(p['lead'], true);
    b[69] = 2;
    expect(KseegProtocol.parse('raw', b)['lead'], false);
    expect(
      KseegProtocol.parse(
        'raw',
        b,
        leadConvention: LeadConvention.windows,
      )['lead'],
      true,
    );
    b[69] = 1;
    expect(KseegProtocol.parse('raw', b)['lead'], false);
  });
}
