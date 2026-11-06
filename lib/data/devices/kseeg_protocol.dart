import 'dart:typed_data';

/// Notification-level F-version 2.1 format, verified against the supplied SDK.
/// No UART framing, sample rate, physical unit, or device sequence is assumed.
enum LeadConvention { android, windows }

abstract final class KseegProtocol {
  static const service = '8653000a-43e6-47b7-9cb0-5fc21d4ae340';
  static const write = '8653000c-43e6-47b7-9cb0-5fc21d4ae340';
  static const uuids = {
    'raw': '8653000b-43e6-47b7-9cb0-5fc21d4ae340',
    'feature': '8653000d-43e6-47b7-9cb0-5fc21d4ae340',
    'frequency': '8653000e-43e6-47b7-9cb0-5fc21d4ae340',
    'other': '8653000f-43e6-47b7-9cb0-5fc21d4ae340',
    'blink_gnash': '86530010-43e6-47b7-9cb0-5fc21d4ae340',
  };
  static const minimumLengths = {
    'raw': 69,
    'feature': 4,
    'frequency': 5,
    'other': 90,
    'blink_gnash': 32,
  };

  static String kindFor(String value) {
    if (minimumLengths.containsKey(value)) return value;
    final normalized = value.toLowerCase();
    for (final entry in uuids.entries) {
      if (entry.value == normalized) return entry.key;
    }
    throw FormatException('未知通知类型：$value');
  }

  static Map<String, Object> parse(
    String uuidOrKind,
    Uint8List bytes, {
    LeadConvention leadConvention = LeadConvention.android,
  }) {
    final kind = kindFor(uuidOrKind);
    final minimum = minimumLengths[kind]!;
    if (bytes.length < minimum) {
      throw FormatException('$kind 通知至少需要 $minimum 字节，实际 ${bytes.length} 字节');
    }
    final data = ByteData.sublistView(bytes);
    switch (kind) {
      case 'raw':
        return {
          'channel_1': List<double>.generate(
            16,
            (i) => data.getUint16(4 + i * 4) / 10000,
          ),
          'channel_2': List<double>.generate(
            16,
            (i) => data.getUint16(6 + i * 4) / 10000,
          ),
          'power': bytes[3],
          'lead': leadConvention == LeadConvention.android
              ? bytes.last == 0
              : bytes.last != 1,
        };
      case 'feature':
        return {
          for (final (i, key) in [
            'attention',
            'relax',
            'tired',
            'meditation',
          ].indexed)
            key: bytes[i],
        };
      case 'frequency':
        return {
          for (final (i, key) in [
            'delta',
            'theta',
            'alpha',
            'beta',
            'gamma',
          ].indexed)
            key: bytes[i],
        };
      case 'blink_gnash':
        return {
          'gnash': List<int>.generate(16, (i) => bytes[i * 2]),
          'blink': List<int>.generate(16, (i) => bytes[i * 2 + 1]),
        };
      case 'other':
        const keys = ['acc_x', 'acc_y', 'acc_z', 'gyro_x', 'gyro_y', 'gyro_z'];
        int optical(int offset) =>
            ((bytes[offset] << 16) |
                (bytes[offset + 1] << 8) |
                bytes[offset + 2]) &
            0x3ffff;
        return {
          for (final (j, key) in keys.indexed)
            key: List<int>.generate(5, (i) => data.getUint16(i * 18 + j * 2)),
          'red': List<int>.generate(5, (i) => optical(i * 18 + 12)),
          'ired': List<int>.generate(5, (i) => optical(i * 18 + 15)),
        };
      default:
        throw FormatException('未实现的通知类型：$kind');
    }
  }
}
