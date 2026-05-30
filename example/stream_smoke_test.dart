import 'dart:async';
import 'dart:io';

import 'package:ntr/ntr.dart';

/// Streams from the 3DS for [Duration] and reports per-screen frame counts.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run example/stream_smoke_test.dart <ip>');
    exitCode = 64;
    return;
  }
  const window = Duration(seconds: 6);
  final session = NtrSession(NtrConfig(ipAddress: args.single));
  var topCount = 0;
  var bottomCount = 0;
  try {
    await session.startStreaming();
    final subscription = session.frames.listen((frame) {
      if (frame.screen == Screen.top) {
        topCount++;
      } else {
        bottomCount++;
      }
    });
    await Future<void>.delayed(window);
    await subscription.cancel();
    stdout.writeln(
      'over ${window.inSeconds}s: top=$topCount bottom=$bottomCount '
      '(${(topCount + bottomCount) / window.inSeconds} fps total)',
    );
  } finally {
    await session.dispose();
  }
}
