import 'dart:async';
import 'dart:convert';

import 'ntr_command.dart';
import 'ntr_config.dart';
import 'ntr_control_connection.dart';
import 'ntr_exceptions.dart';
import 'patches.dart';
import 'screen_frame.dart';
import 'screen_stream_receiver.dart';

/// High-level façade combining the TCP control channel and UDP video
/// receiver. Most callers should use this in preference to wiring
/// [NtrControlConnection] and [ScreenStreamReceiver] together by hand.
final class NtrSession {
  /// Creates a session bound to [config].
  ///
  /// Pass custom [control] / [streamReceiver] only for testing.
  NtrSession(
    NtrConfig config, {
    NtrControlConnection? control,
    ScreenStreamReceiver? streamReceiver,
  })  : _control = control ?? NtrControlConnection(config),
        _streamReceiver = streamReceiver ?? ScreenStreamReceiver() {
    _control.config = config;
  }

  final NtrControlConnection _control;
  final ScreenStreamReceiver _streamReceiver;

  /// All reassembled frames from both screens.
  Stream<ScreenFrame> get frames => _streamReceiver.frames;

  /// Just the top-screen frames.
  Stream<ScreenFrame> get topFrames => _streamReceiver.topFrames;

  /// Just the bottom-screen frames.
  Stream<ScreenFrame> get bottomFrames => _streamReceiver.bottomFrames;

  /// Control-channel lifecycle state.
  Stream<NtrConnectionState> get controlStates => _control.states;

  /// Control-channel responses from the device.
  Stream<NtrResponse> get responses => _control.responses;

  /// Active configuration. Use [updateConfig] to change it.
  NtrConfig get config => _control.config;

  /// Replaces the active configuration. Changes take effect on the next
  /// connect / Remote Play handshake.
  void updateConfig(NtrConfig next) => _control.config = next;

  /// Connects to the device and begins UDP streaming.
  ///
  /// Performs the Remote Play handshake: connect → send command 901 →
  /// disconnect → wait → reconnect → disconnect. The UDP receiver is bound
  /// first so no early frames are missed.
  Future<void> startStreaming() async {
    if (!_streamReceiver.isRunning) {
      await _streamReceiver.start();
    }
    await _control.connect();
    await _control.startRemotePlay();
  }

  /// Stops UDP streaming and tears down the control channel.
  Future<void> stopStreaming() async {
    await _streamReceiver.stop();
    await _control.disconnect();
  }

  /// Sends a raw [NtrCommand]. Lower-level escape hatch — prefer the
  /// higher-level methods ([startStreaming], [applyPatch], …) where possible.
  Future<void> send(
    NtrCommand command, {
    List<int> args = const <int>[],
    List<int> data = const <int>[],
  }) {
    return _control.send(command, args: args, data: data);
  }

  /// Applies a [Patch] via WriteMem.
  ///
  /// If the patch identifies its target by process name, the pid is looked
  /// up by issuing a `pidList` request and parsing the response. Throws
  /// [NtrProtocolException] if the named process is not found.
  Future<void> applyPatch(
    Patch patch, {
    Duration pidListTimeout = const Duration(seconds: 3),
  }) async {
    if (_control.state != NtrConnectionState.connected) {
      await _control.connect();
    }
    final pid = patch.pid ?? await _resolvePid(patch.processName!, pidListTimeout);
    await _control.send(
      NtrCommand.writeMem,
      args: <int>[pid, patch.offset, patch.bytes.length],
      data: patch.bytes,
    );
  }

  Future<int> _resolvePid(String processName, Duration timeout) async {
    final response = _control.responses
        .firstWhere(
          (response) => response.command == NtrCommand.pidList.code,
        )
        .timeout(
          timeout,
          onTimeout: () => throw const NtrTimeoutException(
            'no pidList response',
          ),
        );
    await _control.send(NtrCommand.pidList);
    final payload = await response;
    final text = utf8.decode(payload.payload, allowMalformed: true);
    final pid = findPidByName(text, processName);
    if (pid == null) {
      throw NtrProtocolException('process "$processName" not found');
    }
    return pid;
  }

  /// Releases all resources held by the session.
  Future<void> dispose() async {
    await _streamReceiver.dispose();
    await _control.dispose();
  }
}
