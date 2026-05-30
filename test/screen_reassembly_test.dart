import 'dart:io';
import 'dart:typed_data';

import 'package:ntr/ntr.dart';
import 'package:test/test.dart';

/// Builds one datagram of a streamed frame.
///
/// [screen]: 1 = top, 0 = bottom.
/// [isLast]: sets the `0x10` high-nibble flag in `byte[1]`.
/// [sequenceIndex]: written to `byte[3]`.
Uint8List buildDatagram({
  required int frameId,
  required int screen,
  required bool isLast,
  required int sequenceIndex,
  required Uint8List jpegChunk,
}) {
  final flags = (isLast ? 0x10 : 0x00) | (screen & 0x0f);
  return Uint8List.fromList(<int>[
    frameId,
    flags,
    0, // unused
    sequenceIndex,
    ...jpegChunk,
  ]);
}

Future<void> sendAndAwait(
  RawDatagramSocket sender,
  InternetAddress address,
  int port,
  Uint8List bytes,
) async {
  sender.send(bytes, address, port);
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  group('ScreenStreamReceiver', () {
    late ScreenStreamReceiver receiver;
    late RawDatagramSocket sender;

    setUp(() async {
      receiver = ScreenStreamReceiver();
      await receiver.start();
      sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      sender.close();
      await receiver.dispose();
    });

    test('reassembles a 2-packet top-screen JPEG frame', () async {
      final framesFuture = receiver.topFrames.first;

      // JPEG: FF D8 [body] FF D9
      final part1 = Uint8List.fromList(<int>[0xff, 0xd8, 0xaa, 0xbb]);
      final part2 = Uint8List.fromList(<int>[0xcc, 0xff, 0xd9]);

      await sendAndAwait(
        sender,
        InternetAddress.loopbackIPv4,
        ScreenStreamReceiver.port,
        buildDatagram(
          frameId: 7,
          screen: 1,
          isLast: false,
          sequenceIndex: 0,
          jpegChunk: part1,
        ),
      );
      await sendAndAwait(
        sender,
        InternetAddress.loopbackIPv4,
        ScreenStreamReceiver.port,
        buildDatagram(
          frameId: 7,
          screen: 1,
          isLast: true,
          sequenceIndex: 1,
          jpegChunk: part2,
        ),
      );

      final frame = await framesFuture.timeout(const Duration(seconds: 2));
      expect(frame.screen, Screen.top);
      expect(frame.jpeg, <int>[0xff, 0xd8, 0xaa, 0xbb, 0xcc, 0xff, 0xd9]);
    });

    test('sequence gap discards the frame', () async {
      final framesFuture = receiver.frames.first
          .timeout(const Duration(milliseconds: 500), onTimeout: () {
        throw const NtrTimeoutException('no frame');
      });

      final part1 = Uint8List.fromList(<int>[0xff, 0xd8]);
      final part2 = Uint8List.fromList(<int>[0xff, 0xd9]);

      await sendAndAwait(
        sender,
        InternetAddress.loopbackIPv4,
        ScreenStreamReceiver.port,
        buildDatagram(
          frameId: 4,
          screen: 0,
          isLast: false,
          sequenceIndex: 0,
          jpegChunk: part1,
        ),
      );
      // Skip sequenceIndex 1, jump to 2 — receiver should drop the frame.
      await sendAndAwait(
        sender,
        InternetAddress.loopbackIPv4,
        ScreenStreamReceiver.port,
        buildDatagram(
          frameId: 4,
          screen: 0,
          isLast: true,
          sequenceIndex: 2,
          jpegChunk: part2,
        ),
      );

      expect(framesFuture, throwsA(isA<NtrTimeoutException>()));
    });

    test('malformed JPEG (missing EOI) is rejected', () async {
      final framesFuture = receiver.frames.first
          .timeout(const Duration(milliseconds: 500), onTimeout: () {
        throw const NtrTimeoutException('no frame');
      });

      final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0x11, 0x22]);
      await sendAndAwait(
        sender,
        InternetAddress.loopbackIPv4,
        ScreenStreamReceiver.port,
        buildDatagram(
          frameId: 1,
          screen: 1,
          isLast: true,
          sequenceIndex: 0,
          jpegChunk: bytes,
        ),
      );

      expect(framesFuture, throwsA(isA<NtrTimeoutException>()));
    });
  });
}
