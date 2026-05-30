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
app, decode each frame with `Image.memory`.

> **Platform support.** Uses `dart:io` sockets. Runs on Dart VM and Flutter
> for Android, iOS, macOS, Windows, Linux. Flutter web is **not**
> supported (no UDP, no raw TCP).

## Usage

```dart
import 'package:ntr/ntr.dart';

Future<void> main() async {
  final session = NtrSession(const NtrConfig(ipAddress: '192.168.1.5'));
  await session.startStreaming();

  session.topFrames.listen((frame) {
    // frame.jpeg is a Uint8List — feed to a decoder.
  });

  await session.applyPatch(Patches.universal);
  // ...
  await session.dispose();
}
```

## Acknowledgements

The wire protocol details were verified against the
[cuteNTR](https://gitlab.com/BoltsJ/cuteNTR) Qt reference client.
This package is an independent Dart reimplementation, not a port.
