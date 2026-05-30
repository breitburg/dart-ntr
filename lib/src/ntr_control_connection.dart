import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'control_packet.dart';
import 'ntr_command.dart';
import 'ntr_config.dart';
import 'ntr_exceptions.dart';

/// Lifecycle states of an [NtrControlConnection].
enum NtrConnectionState {
  /// No socket open.
  disconnected,

  /// `Socket.connect` is in flight.
  connecting,

  /// Connected; heartbeats are running.
  connected,
}

/// A response from the device — one [command] result with its [payload].
final class NtrResponse {
  /// Creates a response.
  const NtrResponse({required this.command, required this.payload});

  /// The wire opcode the device echoed back.
  final int command;

  /// Payload bytes (may be empty).
  final Uint8List payload;
}

/// TCP control channel to a 3DS running NTR CFW (port 8000).
///
/// Owns the [Socket], drives a 1-second heartbeat, frames outgoing
/// [NtrCommand]s, and exposes incoming responses on a broadcast [Stream].
final class NtrControlConnection {
  /// Creates a connection bound to [config]. Call [connect] to open it.
  NtrControlConnection(this.config);

  static final Logger _log = Logger('ntr.control');

  /// TCP port the NTR debugger listens on.
  static const int port = 8000;

  /// Interval between heartbeat packets.
  static const Duration heartbeatInterval = Duration(seconds: 1);

  /// Delay after connecting before the auto pidList probe (matches Qt).
  static const Duration initialPidListDelay = Duration(milliseconds: 2500);

  /// Sequence step between successive packets (matches Qt).
  static const int sequenceStep = 1000;

  /// Current [NtrConfig]. Changes take effect on the next connect.
  NtrConfig config;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSubscription;
  Timer? _heartbeatTimer;
  Timer? _initialPidListTimer;

  int _sequence = 0;
  final BytesBuilder _rxBuffer = BytesBuilder(copy: false);
  int _pendingPayloadFor = -1;
  int _pendingPayloadLength = 0;

  final StreamController<NtrConnectionState> _stateController =
      StreamController<NtrConnectionState>.broadcast();
  final StreamController<NtrResponse> _responseController =
      StreamController<NtrResponse>.broadcast();

  NtrConnectionState _state = NtrConnectionState.disconnected;

  /// Current lifecycle state.
  NtrConnectionState get state => _state;

  /// Lifecycle state changes.
  Stream<NtrConnectionState> get states => _stateController.stream;

  /// Decoded responses from the device.
  Stream<NtrResponse> get responses => _responseController.stream;

  /// Opens the TCP socket and starts heartbeats.
  ///
  /// Throws [NtrConnectionException] on failure.
  Future<void> connect({Duration timeout = const Duration(seconds: 5)}) async {
    if (_state != NtrConnectionState.disconnected) {
      throw const NtrConnectionException('already connected');
    }
    _setState(NtrConnectionState.connecting);
    try {
      _socket = await Socket.connect(config.ipAddress, port, timeout: timeout);
    } on SocketException catch (error) {
      _setState(NtrConnectionState.disconnected);
      throw NtrConnectionException('connect failed: ${error.message}');
    } on TimeoutException {
      _setState(NtrConnectionState.disconnected);
      throw const NtrTimeoutException('connect timed out');
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _socketSubscription = _socket!.listen(
      _onBytes,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
    _initialPidListTimer = Timer(initialPidListDelay, () {
      if (_state == NtrConnectionState.connected) {
        unawaited(send(NtrCommand.pidList));
      }
    });
    _setState(NtrConnectionState.connected);
    _log.info('connected to ${config.ipAddress}:$port');
  }

  /// Closes the socket and stops the heartbeat. Idempotent.
  Future<void> disconnect() async {
    _initialPidListTimer?.cancel();
    _initialPidListTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final socket = _socket;
    _socket = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _rxBuffer.clear();
    _pendingPayloadFor = -1;
    _pendingPayloadLength = 0;
    if (socket != null) {
      try {
        await socket.flush();
      } on SocketException {
        // Already closed — nothing to do.
      }
      await socket.close();
      socket.destroy();
    }
    _setState(NtrConnectionState.disconnected);
  }

  /// Sends an [NtrCommand] with optional [args] and [data] payload.
  ///
  /// Throws [NtrConnectionException] if not connected.
  Future<void> send(
    NtrCommand command, {
    List<int> args = const <int>[],
    List<int> data = const <int>[],
  }) async {
    if (command == NtrCommand.empty) {
      _sendHeartbeat();
      return;
    }
    final socket = _socket;
    if (socket == null || _state != NtrConnectionState.connected) {
      throw const NtrConnectionException('not connected');
    }
    final packet = ControlPacket.command(
      command,
      sequence: _nextSequence(),
      args: args,
      payloadLength: data.length,
    );
    socket.add(packet.encode());
    if (data.isNotEmpty) {
      socket.add(data);
    }
  }

  /// Sends the Remote Play (code 901) request and performs the disconnect
  /// → wait → reconnect → disconnect dance the device requires before it
  /// starts pushing UDP frames.
  Future<void> startRemotePlay({
    Duration settleDelay = const Duration(seconds: 3),
  }) async {
    final socket = _socket;
    if (socket == null || _state != NtrConnectionState.connected) {
      throw const NtrConnectionException('not connected');
    }
    _log.info('starting Remote Play');
    final packet = ControlPacket.remotePlay(
      sequence: _nextSequence(),
      args: config.remotePlayArgs,
    );
    socket.add(packet.encode());
    await socket.flush();
    await disconnect();
    await Future<void>.delayed(settleDelay);
    await connect();
    await disconnect();
  }

  void _sendHeartbeat() {
    final socket = _socket;
    if (socket == null) return;
    final packet = ControlPacket.command(
      NtrCommand.empty,
      sequence: _nextSequence(),
    );
    socket.add(packet.encode());
  }

  int _nextSequence() {
    _sequence += sequenceStep;
    return _sequence;
  }

  void _onBytes(Uint8List chunk) {
    _rxBuffer.add(chunk);
    _drainBuffer();
  }

  void _drainBuffer() {
    while (true) {
      if (_pendingPayloadFor < 0) {
        if (_rxBuffer.length < ntrPacketBytes) return;
        final all = _rxBuffer.takeBytes();
        final header = Uint8List.sublistView(all, 0, ntrPacketBytes);
        final ControlPacket parsed;
        try {
          parsed = ControlPacket.decode(header);
        } on NtrProtocolException catch (error) {
          _log.warning(error.message);
          if (all.length > ntrPacketBytes) {
            _rxBuffer.add(Uint8List.sublistView(all, ntrPacketBytes));
          }
          continue;
        }
        if (all.length > ntrPacketBytes) {
          _rxBuffer.add(Uint8List.sublistView(all, ntrPacketBytes));
        }
        _pendingPayloadFor = parsed.code;
        _pendingPayloadLength = parsed.payloadLength;
        if (_pendingPayloadLength == 0) {
          _emitResponse(Uint8List(0));
        }
      } else {
        if (_rxBuffer.length < _pendingPayloadLength) return;
        final all = _rxBuffer.takeBytes();
        final payload =
            Uint8List.sublistView(all, 0, _pendingPayloadLength);
        if (all.length > _pendingPayloadLength) {
          _rxBuffer.add(Uint8List.sublistView(all, _pendingPayloadLength));
        }
        _emitResponse(Uint8List.fromList(payload));
      }
    }
  }

  void _emitResponse(Uint8List payload) {
    final command = _pendingPayloadFor;
    _pendingPayloadFor = -1;
    _pendingPayloadLength = 0;
    if (!_responseController.isClosed) {
      _responseController
          .add(NtrResponse(command: command, payload: payload));
    }
  }

  void _onSocketError(Object error, StackTrace stackTrace) {
    _log.warning('socket error: $error');
    unawaited(disconnect());
  }

  void _onSocketDone() {
    _log.info('socket closed by peer');
    unawaited(disconnect());
  }

  void _setState(NtrConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  /// Releases all resources. The connection cannot be reused afterwards.
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
    await _responseController.close();
  }
}
