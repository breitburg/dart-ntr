/// A command in the NTR debugger protocol.
///
/// Each value carries the on-the-wire `type` and `code` used by NTR CFW,
/// which differ from the original C++ enum's source ordinals. See
/// `src/ntr.cpp` in the upstream Qt client for the reference mapping.
///
/// `RemotePlay` (code 901) is intentionally absent: it is a request with a
/// bespoke disconnect/reconnect dance and is exposed as a dedicated method
/// on the connection.
enum NtrCommand {
  /// Heartbeat. Sent once per second to keep the TCP socket alive.
  empty(type: 0, code: 0),

  /// Write a save file. Followed by the save data on the wire.
  writeSave(type: 1, code: 1),

  /// Hello / handshake.
  hello(type: 0, code: 3),

  /// Reload the NTR plugin on the device.
  reload(type: 0, code: 4),

  /// Request the list of running processes.
  pidList(type: 0, code: 5),

  /// Attach to a process by pid.
  attachProcess(type: 0, code: 6),

  /// Request the list of threads in the attached process.
  threadList(type: 0, code: 7),

  /// Request the memory layout of the attached process.
  memLayout(type: 0, code: 8),

  /// Read process memory. Response payload contains the bytes read.
  readMem(type: 1, code: 9),

  /// Write process memory. Followed by the bytes to write on the wire.
  writeMem(type: 1, code: 10);

  const NtrCommand({required this.type, required this.code});

  /// Packet `type` field. `1` for commands that carry a payload, else `0`.
  final int type;

  /// Packet `cmd` field — the wire opcode the device dispatches on.
  final int code;
}
