import 'dart:async';
import 'dart:io';

/// A host that responded to the TCP probe.
class DiscoveredDevice {
  DiscoveredDevice({required this.ipAddress, required this.discoveredAt});

  final String ipAddress;
  final DateTime discoveredAt;
}

/// Scans the local IPv4 /24 for hosts accepting TCP connections on the NTR
/// debugger port (8000).
class NetworkScanner {
  NetworkScanner({this.port = 8000, this.probeTimeout = const Duration(milliseconds: 400)});

  final int port;
  final Duration probeTimeout;

  /// Returns every host on each non-loopback IPv4 /24 the device is on that
  /// accepts a TCP connection on [port].
  Stream<DiscoveredDevice> scan() async* {
    final subnets = await _localSubnets();
    if (subnets.isEmpty) return;
    final hits = StreamController<DiscoveredDevice>();
    final futures = <Future<void>>[];
    for (final subnet in subnets) {
      for (var host = 1; host <= 254; host++) {
        final address = '$subnet.$host';
        futures.add(_probe(address).then((open) {
          if (open && !hits.isClosed) {
            hits.add(
              DiscoveredDevice(
                ipAddress: address,
                discoveredAt: DateTime.now(),
              ),
            );
          }
        }));
      }
    }
    unawaited(Future.wait(futures).whenComplete(hits.close));
    yield* hits.stream;
  }

  Future<List<String>> _localSubnets() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final subnets = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final parts = address.address.split('.');
        if (parts.length == 4) {
          subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    }
    return subnets.toList();
  }

  Future<bool> _probe(String host) async {
    try {
      final socket = await Socket.connect(host, port, timeout: probeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
