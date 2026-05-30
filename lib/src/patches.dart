import 'dart:typed_data';

/// A WriteMem patch: a byte sequence to splice into a running process at a
/// given memory offset.
///
/// Exactly one of [pid] or [processName] must be set. When [processName] is
/// used the session resolves it to a pid by sending a `pidList` request and
/// scanning the response.
final class Patch {
  /// Patches a fixed [pid].
  Patch.byPid({
    required int this.pid,
    required this.offset,
    required this.bytes,
  }) : processName = null;

  /// Patches a process resolved by [name] from the device's `pidList` response.
  Patch.byProcessName({
    required String name,
    required this.offset,
    required this.bytes,
  })  : pid = null,
        processName = name;

  /// Pinned pid, or `null` if the patch targets a process by [processName].
  final int? pid;

  /// Process name to look up at apply-time, or `null` if [pid] is pinned.
  final String? processName;

  /// Byte offset in the target process's memory.
  final int offset;

  /// Bytes to write.
  final Uint8List bytes;
}

/// Common built-in patches applied via NTR CFW: the canonical universal NFC
/// patch and a Pokémon Sun/Moon 1.1 variant. Both verified against the Qt
/// cuteNTR reference client.
abstract final class Patches {
  /// The "universal NFC" patch (pid 0x1a, two-byte ARM Thumb `BX LR`).
  static final Patch universal = Patch.byPid(
    pid: 0x1a,
    offset: 0x105ae4,
    bytes: Uint8List.fromList(<int>[0x70, 0x47]),
  );

  /// Pokémon Sun / Moon 1.1 NFC patch (process `niji_loc`).
  static final Patch pokemonSunMoon = Patch.byProcessName(
    name: 'niji_loc',
    offset: 0x3e14c0,
    bytes: Uint8List.fromList(<int>[0xe3, 0xa0, 0x10, 0x00]),
  );
}

/// Parses a pidList response payload and returns the pid of the entry whose
/// process name contains [processName], or `null` if not found.
///
/// The payload (as written by NTR CFW) is a text blob with one line per
/// process. Each line begins with `pid: <hex>` followed by `pname: <name>`
/// and other fields. This parser extracts the hex pid from any line whose
/// text contains [processName].
int? findPidByName(String payload, String processName) {
  final pidPattern = RegExp(r'pid:\s*([0-9a-fA-F]+)');
  for (final line in payload.split('\n')) {
    if (!line.contains(processName)) continue;
    final match = pidPattern.firstMatch(line);
    if (match == null) continue;
    final pid = int.tryParse(match.group(1)!, radix: 16);
    if (pid != null) return pid;
  }
  return null;
}
