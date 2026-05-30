import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'network_scanner.dart';
import 'streaming_page.dart';

/// Lists every host on the LAN that accepts TCP 8000.
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final NetworkScanner _scanner = NetworkScanner();
  final List<DiscoveredDevice> _devices = <DiscoveredDevice>[];
  StreamSubscription<DiscoveredDevice>? _subscription;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    await _subscription?.cancel();
    setState(() {
      _devices.clear();
      _scanning = true;
    });
    _subscription = _scanner.scan().listen(
      (device) {
        setState(() {
          if (!_devices.any((existing) => existing.ipAddress == device.ipAddress)) {
            _devices.add(device);
            _devices.sort((a, b) => _ipSortKey(a.ipAddress)
                .compareTo(_ipSortKey(b.ipAddress)));
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  int _ipSortKey(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  void _openDevice(DiscoveredDevice device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StreamingPage(ipAddress: device.ipAddress),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('3DS on this network'),
        actions: <Widget>[
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CupertinoActivityIndicator(),
                  )
                : const Icon(Icons.refresh),
            onPressed: _scanning ? null : _startScan,
            tooltip: 'Rescan',
          ),
        ],
      ),
      body: _devices.isEmpty
          ? _EmptyState(scanning: _scanning, onRetry: _startScan)
          : ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final device = _devices[index];
                return ListTile(
                  leading: const Icon(CupertinoIcons.gamecontroller),
                  title: Text(device.ipAddress),
                  subtitle: const Text('TCP 8000 open — likely NTR debugger'),
                  trailing: const Icon(CupertinoIcons.chevron_forward),
                  onTap: () => _openDevice(device),
                );
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.scanning, required this.onRetry});

  final bool scanning;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(CupertinoIcons.wifi_exclamationmark, size: 48),
            const SizedBox(height: 16),
            Text(
              scanning ? 'Scanning the local network…' : 'No devices found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Make sure your 3DS is running NTR CFW and is on the same '
              'Wi-Fi network as this device.',
              textAlign: TextAlign.center,
            ),
            if (!scanning) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
