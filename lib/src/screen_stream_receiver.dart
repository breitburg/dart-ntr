import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'ntr_exceptions.dart';
import 'screen_frame.dart';

/// Reassembles UDP screen frames pushed by NTR CFW Remote Play (port 8001).
///
/// Per-datagram header (≤2000 bytes total):
/// * `byte[0]` — frame id (changes per frame)
/// * `byte[1]` — high nibble: terminator flag (`0x10` = last packet of frame);
///   low nibble: screen (1 = top, 0 = bottom)
/// * `byte[3]` — sequence index within the frame; gap = drop the frame
/// * `byte[4..]` — JPEG payload chunk
///
/// A complete frame is validated to start with `FF D8` and end with `FF D9`.
final class ScreenStreamReceiver {
  /// Creates a receiver. Call [start] to bind the UDP socket and listen.
  ScreenStreamReceiver();

  static final Logger _log = Logger('ntr.stream');

  /// UDP port the device pushes frames to.
  static const int port = 8001;

  /// Window of silence after which the receiver surfaces an [NtrTimeoutException].
  static const Duration inactivityTimeout = Duration(seconds: 5);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _inactivityTimer;

  int? _currentFrameId;
  int _expectedIndex = 0;
  final BytesBuilder _currentFrame = BytesBuilder(copy: false);

  final StreamController<ScreenFrame> _framesController =
      StreamController<ScreenFrame>.broadcast();

  /// All reassembled frames from both screens.
  Stream<ScreenFrame> get frames => _framesController.stream;

  /// Convenience: just the top-screen frames.
  Stream<ScreenFrame> get topFrames =>
      frames.where((frame) => frame.screen == Screen.top);

  /// Convenience: just the bottom-screen frames.
  Stream<ScreenFrame> get bottomFrames =>
      frames.where((frame) => frame.screen == Screen.bottom);

  /// Whether the UDP socket is bound and listening.
  bool get isRunning => _socket != null;

  /// Binds the UDP socket and starts dispatching frames.
  ///
  /// Throws [NtrConnectionException] if the bind fails.
  Future<void> start() async {
    if (_socket != null) {
      throw const NtrConnectionException('stream receiver already running');
    }
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException catch (error) {
      throw NtrConnectionException(
        'failed to bind UDP $port: ${error.message}',
      );
    }
    _socketSubscription = _socket!.listen(
      _onEvent,
      onError: (Object error, StackTrace stack) {
        _log.warning('UDP socket error: $error');
      },
    );
    _armInactivityTimer();
    _log.info('listening for screen frames on UDP $port');
  }

  /// Stops listening and releases the UDP socket. Idempotent.
  Future<void> stop() async {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    _resetFrame();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _handleDatagram(datagram!.data);
    }
  }

  void _handleDatagram(Uint8List bytes) {
    _armInactivityTimer();
    if (bytes.length < 4) {
      _log.fine('discarding tiny datagram (${bytes.length} bytes)');
      _resetFrame();
      return;
    }
    final frameId = bytes[0];
    final flagsAndScreen = bytes[1];
    final packetIndex = bytes[3];
    final isLast = (flagsAndScreen & 0xf0) == 0x10;
    final screenNibble = flagsAndScreen & 0x0f;

    if (_currentFrameId == null || _currentFrameId != frameId) {
      _currentFrameId = frameId;
      _expectedIndex = 0;
      _currentFrame.clear();
    } else {
      if (packetIndex != _expectedIndex) {
        _log.fine(
          'sequence gap (got $packetIndex, expected $_expectedIndex); '
          'dropping frame $frameId',
        );
        _resetFrame();
        return;
      }
    }

    _currentFrame.add(Uint8List.sublistView(bytes, 4));
    _expectedIndex++;

    if (!isLast) return;

    final jpeg = _currentFrame.takeBytes();
    _resetFrame();
    if (!_isValidJpeg(jpeg)) {
      _log.fine('malformed JPEG (bad SOI/EOI); dropping');
      return;
    }
    final screen = switch (screenNibble) {
      1 => Screen.top,
      0 => Screen.bottom,
      _ => null,
    };
    if (screen == null) {
      _log.fine('unknown screen nibble 0x${screenNibble.toRadixString(16)}');
      return;
    }
    if (!_framesController.isClosed) {
      _framesController.add(ScreenFrame(screen: screen, jpeg: jpeg));
    }
  }

  void _resetFrame() {
    _currentFrameId = null;
    _expectedIndex = 0;
    _currentFrame.clear();
  }

  bool _isValidJpeg(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9;
  }

  void _armInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityTimeout, () {
      _log.warning('no frames received for ${inactivityTimeout.inSeconds}s');
      if (!_framesController.isClosed) {
        _framesController.addError(
          const NtrTimeoutException('no UDP frames received'),
        );
      }
    });
  }

  /// Releases all resources. The receiver cannot be reused afterwards.
  Future<void> dispose() async {
    await stop();
    await _framesController.close();
  }
}
