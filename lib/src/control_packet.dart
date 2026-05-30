import 'dart:typed_data';

import 'ntr_command.dart';
import 'ntr_exceptions.dart';

/// Magic value at offset 0 of every NTR control packet.
const int ntrPacketMagic = 0x12345678;

/// Total size of a control packet header, in bytes.
///
/// 21 little-endian `uint32` slots: magic, sequence, type, cmd, 16 args,
/// payload length.
const int ntrPacketBytes = 21 * 4;

const int _maxArgs = 16;

/// Builds and parses the 84-byte NTR control packet.
///
/// The wire layout is 21 little-endian `uint32` slots:
/// `[0]=magic`, `[1]=sequence`, `[2]=type`, `[3]=cmd`, `[4..19]=args`,
/// `[20]=payload length`. Data payloads (for `writeMem`, `writeSave`)
/// follow the header on the same TCP stream.
final class ControlPacket {
  /// Constructs a packet with all fields explicit. Most callers should
  /// use [ControlPacket.command] or [ControlPacket.remotePlay] instead.
  ControlPacket({
    required this.sequence,
    required this.type,
    required this.code,
    required this.args,
    this.payloadLength = 0,
  }) {
    if (args.length > _maxArgs) {
      throw ArgumentError.value(
        args.length,
        'args.length',
        'at most $_maxArgs arguments are allowed',
      );
    }
  }

  /// Builds a packet for an [NtrCommand].
  factory ControlPacket.command(
    NtrCommand command, {
    required int sequence,
    List<int> args = const <int>[],
    int payloadLength = 0,
  }) {
    return ControlPacket(
      sequence: sequence,
      type: command.type,
      code: command.code,
      args: args,
      payloadLength: payloadLength,
    );
  }

  /// Builds the Remote Play request (special wire code 901).
  factory ControlPacket.remotePlay({
    required int sequence,
    required List<int> args,
  }) {
    return ControlPacket(
      sequence: sequence,
      type: 0,
      code: 901,
      args: args,
    );
  }

  /// Sequence counter. The Qt reference client advances by 1000 per packet.
  final int sequence;

  /// Packet `type` field.
  final int type;

  /// Packet `cmd` field — the wire opcode.
  final int code;

  /// Command arguments (zero-padded out to 16 slots on the wire).
  final List<int> args;

  /// Length of the payload that follows this header on the TCP stream.
  final int payloadLength;

  /// Encodes the header as 84 little-endian bytes.
  Uint8List encode() {
    final bytes = Uint8List(ntrPacketBytes);
    final view = ByteData.sublistView(bytes);
    view.setUint32(0, ntrPacketMagic, Endian.little);
    view.setUint32(4, sequence, Endian.little);
    view.setUint32(8, type, Endian.little);
    view.setUint32(12, code, Endian.little);
    for (var index = 0; index < args.length; index++) {
      view.setUint32(16 + index * 4, args[index], Endian.little);
    }
    view.setUint32(80, payloadLength, Endian.little);
    return bytes;
  }

  /// Decodes an 84-byte header.
  ///
  /// Throws [NtrProtocolException] if the magic number does not match.
  /// Throws [ArgumentError] if [bytes] is the wrong length.
  factory ControlPacket.decode(Uint8List bytes) {
    if (bytes.length != ntrPacketBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'expected exactly $ntrPacketBytes bytes',
      );
    }
    final view = ByteData.sublistView(bytes);
    final magic = view.getUint32(0, Endian.little);
    if (magic != ntrPacketMagic) {
      throw NtrProtocolException(
        'bad NTR packet magic: 0x${magic.toRadixString(16)}',
      );
    }
    return ControlPacket(
      sequence: view.getUint32(4, Endian.little),
      type: view.getUint32(8, Endian.little),
      code: view.getUint32(12, Endian.little),
      args: <int>[
        for (var index = 0; index < _maxArgs; index++)
          view.getUint32(16 + index * 4, Endian.little),
      ],
      payloadLength: view.getUint32(80, Endian.little),
    );
  }
}
