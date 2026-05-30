# ntr

Pure-Dart implementation of the NTR CFW protocol for the Nintendo 3DS.

- TCP control channel (port 8000) — connect, heartbeat, send debugger
  commands (`pidList`, `readMem`, `writeMem`, …), receive responses.
- UDP screen streaming (port 8001) — Remote Play handshake, JPEG frame
  reassembly, separate top and bottom screen streams.
- WriteMem patch surface — apply built-in patches (universal NFC, Pokémon
  Sun/Moon 1.1) or your own.

Transport-only. The package emits raw JPEG bytes (`Uint8List`) and exposes
debugger commands; rendering and UI are left to the caller. In a Flutter
app, decode each frame with `Image.memory` — see `example/viewer/` for a
working iOS + macOS app that discovers 3DS devices on the LAN and streams
both screens with layout / rotation / smoothing controls.

> **Platform support.** Uses `dart:io` sockets. Runs on Dart VM and Flutter
> for Android, iOS, macOS, Windows, Linux. Flutter web is **not**
> supported (no UDP, no raw TCP).

## Install

```yaml
dependencies:
  ntr: ^0.1.0
```

## Guide

### 1. Connect and stream both screens

`NtrSession` is the high-level entry point. Creating one does nothing on
its own; `startStreaming()` performs the Remote Play handshake (TCP
connect → command 901 → disconnect → wait → reconnect → disconnect) and
begins listening on UDP 8001. Frames arrive on a broadcast `Stream`.

```dart
import 'package:ntr/ntr.dart';

Future<void> main() async {
  final session = NtrSession(const NtrConfig(ipAddress: '192.168.1.5'));

  await session.startStreaming();

  session.topFrames.listen((frame) {
    // frame.jpeg is a Uint8List — feed to any decoder.
  });
  session.bottomFrames.listen((frame) {
    // ...
  });

  // When done:
  await session.dispose();
}
```

`topFrames` / `bottomFrames` are filtered convenience streams; the
combined feed is `session.frames` (`Stream<ScreenFrame>` where
`ScreenFrame.screen` is `Screen.top` or `Screen.bottom`).

> **Heads-up.** The device sends frames rotated 90°: the decoded JPEGs are
> portrait (top 240×400, bottom 240×320). Apply a quarter turn at render
> time (`RotatedBox(quarterTurns: 3)` in Flutter) to get the on-device
> orientation back.

### 2. Tune the stream

The defaults match the upstream Qt reference client (JPEG quality 80,
priorityMode 1, priorityFactor 5, qosValue 105). Override anything via
`NtrConfig` before calling `startStreaming`:

```dart
final session = NtrSession(const NtrConfig(
  ipAddress: '192.168.1.5',
  jpegQuality: 90,       // higher = sharper, more bandwidth
  priorityMode: 1,       // 0 = bottom, 1 = top, 2 = neither
  priorityFactor: 5,     // 0–15; higher = stronger bias
  qosValue: 105,         // bandwidth budget (wire field = qosValue << 17)
));
```

### 3. Save a single frame

`ScreenFrame.jpeg` is already a valid JPEG byte stream — just write it.

```dart
import 'dart:io';

final frame = await session.topFrames.first;
await File('/tmp/3ds_top.jpg').writeAsBytes(frame.jpeg);
```

### 4. Discover a 3DS on the local network

`NtrSession` doesn't help with discovery — it needs an IP. NTR doesn't
advertise itself via mDNS, so the cheapest reliable approach is a TCP
probe on port 8000 across the local /24:

```dart
import 'dart:io';

Future<List<String>> scan({
  String subnet = '192.168.1',
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  final hits = <String>[];
  await Future.wait(<Future<void>>[
    for (var host = 1; host <= 254; host++)
      Socket.connect('$subnet.$host', 8000, timeout: timeout)
          .then((socket) {
        socket.destroy();
        hits.add('$subnet.$host');
      }).catchError((_) {}),
  ]);
  return hits..sort();
}
```

The Flutter example (`example/viewer/lib/src/network_scanner.dart`)
extends this to enumerate **every** non-loopback IPv4 /24 the device is
attached to via `NetworkInterface.list()`, so the scan works wherever the
user's Wi-Fi happens to be addressed.

### 5. Apply a WriteMem patch

Two built-in patches ship with the package — the canonical universal NFC
patch and a Pokémon Sun/Moon 1.1 variant. Both target their process by
name where appropriate; `applyPatch` resolves the name to a pid via a
`pidList` round-trip and then issues `writeMem`.

```dart
await session.applyPatch(Patches.universal);
await session.applyPatch(Patches.pokemonSunMoon);
```

Custom patches:

```dart
import 'dart:typed_data';

final patch = Patch.byPid(
  pid: 0x1a,
  offset: 0x105ae4,
  bytes: Uint8List.fromList(<int>[0x70, 0x47]),
);
await session.applyPatch(patch);
```

### 6. Send raw debugger commands

The full debugger surface is exposed as the `NtrCommand` enum
(`pidList`, `readMem`, `writeMem`, `memLayout`, `threadList`, …). Send
one and await its response on `session.responses`:

```dart
final response = session.responses
    .firstWhere((r) => r.command == NtrCommand.pidList.code);
await session.send(NtrCommand.pidList);
final payload = (await response).payload;  // raw bytes from the device
```

## Example app

A full Flutter viewer for iOS and macOS lives in `example/viewer/`:

```bash
cd example/viewer
flutter run -d macos    # or: flutter run -d <iPhone>
```

It scans the LAN, lists every host with TCP 8000 open, taps one to start
streaming both screens with a chrome-less viewer, and exposes layout
(stacked / side-by-side / top-only / bottom-only), rotation, and
smoothing controls via a long-press menu.

## Acknowledgements

The wire protocol details were verified against the
[cuteNTR](https://gitlab.com/BoltsJ/cuteNTR) Qt reference client.
This package is an independent Dart reimplementation, not a port.
