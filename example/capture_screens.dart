import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:ntr/ntr.dart';

/// Connects to the 3DS, kicks off Remote Play, writes one JPEG per screen
/// to `/tmp/`, and opens both with `open`.
///
/// Usage: `dart run example/capture_screens.dart <ipAddress>`
Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln('[${record.level.name}] ${record.loggerName}: ${record.message}');
  });

  if (args.length != 1) {
    stderr.writeln('usage: dart run example/capture_screens.dart <ipAddress>');
    exitCode = 64;
    return;
  }

  final session = NtrSession(NtrConfig(ipAddress: args.single));

  try {
    await session.startStreaming();

    stderr.writeln('waiting for first top + bottom frame...');
    final topFuture = session.topFrames.first
        .timeout(const Duration(seconds: 30));
    final bottomFuture = session.bottomFrames.first
        .timeout(const Duration(seconds: 30));

    final top = await topFuture;
    final bottom = await bottomFuture;

    final topPath = '/tmp/3ds_top.jpg';
    final bottomPath = '/tmp/3ds_bottom.jpg';
    await File(topPath).writeAsBytes(top.jpeg, flush: true);
    await File(bottomPath).writeAsBytes(bottom.jpeg, flush: true);
    stderr.writeln('saved $topPath (${top.jpeg.length} bytes), '
        '$bottomPath (${bottom.jpeg.length} bytes)');

    final openResult =
        await Process.run('open', <String>[topPath, bottomPath]);
    if (openResult.exitCode != 0) {
      stderr.writeln('open failed: ${openResult.stderr}');
    }
  } finally {
    await session.dispose();
  }
}
