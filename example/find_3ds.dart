import 'dart:async';
import 'dart:io';

/// Probes TCP 8000 on every host of the /24 reachable on the current LAN and
/// prints those that accept the connection. The NTR debugger listens on 8000.
Future<void> main() async {
  const subnetPrefix = '192.168.0.';
  const port = 8000;
  const probeTimeout = Duration(milliseconds: 400);

  final hits = <String>[];
  await Future.wait(<Future<void>>[
    for (var host = 1; host <= 254; host++)
      _probe('$subnetPrefix$host', port, probeTimeout).then((open) {
        if (open) {
          hits.add('$subnetPrefix$host');
        }
      }),
  ]);

  hits.sort();
  if (hits.isEmpty) {
    stderr.writeln('no host on $subnetPrefix/24 has TCP $port open');
    exitCode = 1;
    return;
  }
  for (final hit in hits) {
    stdout.writeln(hit);
  }
}

Future<bool> _probe(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
