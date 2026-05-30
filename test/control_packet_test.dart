import 'dart:typed_data';

import 'package:ntr/ntr.dart';
import 'package:test/test.dart';

int littleEndianUint32(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes).getUint32(offset, Endian.little);
}

void main() {
  group('ControlPacket.encode', () {
    test('heartbeat is 84 bytes with only magic and sequence set', () {
      final encoded = ControlPacket.command(
        NtrCommand.empty,
        sequence: 1000,
      ).encode();

      expect(encoded, hasLength(ntrPacketBytes));
      expect(littleEndianUint32(encoded, 0), ntrPacketMagic);
      expect(littleEndianUint32(encoded, 4), 1000);
      expect(littleEndianUint32(encoded, 8), 0);
      expect(littleEndianUint32(encoded, 12), 0);
      expect(littleEndianUint32(encoded, 80), 0);
    });

    test('pidList encodes type=0 cmd=5', () {
      final encoded = ControlPacket.command(
        NtrCommand.pidList,
        sequence: 2000,
      ).encode();

      expect(littleEndianUint32(encoded, 8), 0);
      expect(littleEndianUint32(encoded, 12), 5);
    });

    test('writeMem encodes type=1 cmd=10 with args and payload length', () {
      final encoded = ControlPacket.command(
        NtrCommand.writeMem,
        sequence: 3000,
        args: <int>[0x1a, 0x105ae4, 2],
        payloadLength: 2,
      ).encode();

      expect(littleEndianUint32(encoded, 8), 1);
      expect(littleEndianUint32(encoded, 12), 10);
      expect(littleEndianUint32(encoded, 16), 0x1a);
      expect(littleEndianUint32(encoded, 20), 0x105ae4);
      expect(littleEndianUint32(encoded, 24), 2);
      expect(littleEndianUint32(encoded, 80), 2);
    });

    test('Remote Play encodes cmd=901 with config-derived args', () {
      const config = NtrConfig(ipAddress: '10.0.0.5');
      final encoded = ControlPacket.remotePlay(
        sequence: 1000,
        args: config.remotePlayArgs,
      ).encode();

      expect(littleEndianUint32(encoded, 12), 901);
      // priorityMode=1, priorityFactor=5 → (1<<8)|5 = 0x105
      expect(littleEndianUint32(encoded, 16), (1 << 8) | 5);
      expect(littleEndianUint32(encoded, 20), 80);
      expect(littleEndianUint32(encoded, 24), 105 << 17);
      expect(littleEndianUint32(encoded, 28), 0);
    });

    test('arg overflow throws ArgumentError', () {
      expect(
        () => ControlPacket(
          sequence: 0,
          type: 0,
          code: 0,
          args: List<int>.filled(17, 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ControlPacket.decode', () {
    test('round-trips a writeMem header', () {
      final encoded = ControlPacket.command(
        NtrCommand.writeMem,
        sequence: 4000,
        args: <int>[0x1a, 0x105ae4, 2],
        payloadLength: 2,
      ).encode();

      final decoded = ControlPacket.decode(encoded);

      expect(decoded.sequence, 4000);
      expect(decoded.type, 1);
      expect(decoded.code, 10);
      expect(decoded.args.take(3), <int>[0x1a, 0x105ae4, 2]);
      expect(decoded.payloadLength, 2);
    });

    test('bad magic throws NtrProtocolException', () {
      final bytes = Uint8List(ntrPacketBytes);
      // Magic stays zero — definitely wrong.
      expect(
        () => ControlPacket.decode(bytes),
        throwsA(isA<NtrProtocolException>()),
      );
    });

    test('wrong byte length throws ArgumentError', () {
      expect(
        () => ControlPacket.decode(Uint8List(10)),
        throwsArgumentError,
      );
    });
  });

  group('NtrConfig', () {
    test('defaults match the Qt client', () {
      const config = NtrConfig(ipAddress: '1.2.3.4');

      expect(config.jpegQuality, 80);
      expect(config.priorityMode, 1);
      expect(config.priorityFactor, 5);
      expect(config.qosValue, 105);
      expect(config.remotePlayArgs, <int>[(1 << 8) | 5, 80, 105 << 17, 0]);
    });

    test('copyWith and equality', () {
      const original = NtrConfig(ipAddress: '1.2.3.4');
      final updated = original.copyWith(jpegQuality: 90);

      expect(updated.jpegQuality, 90);
      expect(updated.ipAddress, '1.2.3.4');
      expect(updated == original, isFalse);
      expect(updated == original.copyWith(jpegQuality: 90), isTrue);
      expect(updated.hashCode, original.copyWith(jpegQuality: 90).hashCode);
    });
  });
}
