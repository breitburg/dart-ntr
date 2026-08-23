import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'view_options.dart';

/// Drives the iOS Picture in Picture window.
///
/// There is no `AVPlayer` behind the viewer — frames arrive as JPEGs over UDP —
/// so the iOS runner renders them into an `AVSampleBufferDisplayLayer` and
/// hands that to AVKit. This class is the Dart half: it forwards the latest
/// frames and the current layout, and reports back when the floating window
/// opens or closes.
///
/// Backgrounding the app hands off to PiP automatically; [start] is there for
/// the explicit button in the options sheet.
class PictureInPicture {
  PictureInPicture() {
    if (isAvailable) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static const MethodChannel _channel = MethodChannel('ntr_viewer/pip');

  /// Frame rate pushed to the native layer while the app is in the foreground.
  ///
  /// The layer has to hold recent content for AVKit to consider PiP possible,
  /// but nothing is on screen yet, so a trickle is enough.
  static const Duration _idleInterval = Duration(milliseconds: 200);

  /// Frame rate pushed while the PiP window is actually showing.
  static const Duration _activeInterval = Duration(milliseconds: 33);

  /// The plugin only ships in the iOS runner.
  static bool get isAvailable => !kIsWeb && Platform.isIOS;

  /// Whether the device itself can do PiP. Meaningless before [initialize].
  bool get isSupported => _supported;
  bool _supported = false;

  /// Whether the floating window is currently showing.
  bool get isActive => _active;
  bool _active = false;

  /// Last error reported by AVKit, if a start attempt failed.
  String? get lastError => _lastError;
  String? _lastError;

  bool _enabled = false;
  bool _foreground = true;
  bool _inFlight = false;
  bool _dirty = false;
  bool _disposed = false;
  Timer? _pump;

  Uint8List? _top;
  Uint8List? _bottom;
  ScreenLayout _layout = ScreenLayout.stacked;
  int _quarterTurns = 3;

  /// Asks the platform whether PiP is available at all.
  Future<bool> initialize() async {
    if (!isAvailable) return false;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException catch (error) {
      debugPrint('pip: isSupported failed: $error');
      _supported = false;
    }
    return _supported;
  }

  /// Creates (or tears down) the native layer and PiP controller.
  ///
  /// While enabled the app keeps feeding frames so that iOS can hand off the
  /// moment the app is backgrounded.
  Future<void> setEnabled(bool value) async {
    if (!isAvailable || !_supported || _enabled == value) return;
    _enabled = value;
    try {
      if (value) {
        final ok = await _channel.invokeMethod<bool>('enable') ?? false;
        if (!ok) {
          _enabled = false;
          return;
        }
        await _pushLayout();
        _restartPump();
      } else {
        _pump?.cancel();
        _pump = null;
        await _channel.invokeMethod<void>('disable');
        _setActive(false);
      }
    } on PlatformException catch (error) {
      debugPrint('pip: setEnabled($value) failed: $error');
      _enabled = false;
    }
  }

  /// Keeps the PiP composite in sync with what the viewer is showing.
  void setLayout(ScreenLayout layout, int quarterTurns) {
    if (_layout == layout && _quarterTurns == quarterTurns) return;
    _layout = layout;
    _quarterTurns = quarterTurns;
    unawaited(_pushLayout());
  }

  /// Records the newest frame for a screen. Frames are coalesced and sent on
  /// the pump's schedule, so calling this at full stream rate is fine.
  void submitFrame({Uint8List? top, Uint8List? bottom}) {
    if (top != null) _top = top;
    if (bottom != null) _bottom = bottom;
    _dirty = true;
  }

  /// Opens the floating window now. Returns false if AVKit is not ready —
  /// usually because no frame has been enqueued yet.
  Future<bool> start() async {
    if (!isAvailable || !_enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException catch (error) {
      debugPrint('pip: start failed: $error');
      return false;
    }
  }

  /// Closes the floating window.
  Future<void> stop() async {
    if (!isAvailable || !_enabled) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      debugPrint('pip: stop failed: $error');
    }
  }

  /// Called from the page's lifecycle observer. Leaving the foreground bumps
  /// the frame rate so the hand-off does not start on a stale image.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _restartPump();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pump?.cancel();
    _pump = null;
    if (isAvailable) {
      _channel.setMethodCallHandler(null);
      if (_enabled) {
        _enabled = false;
        try {
          await _channel.invokeMethod<void>('disable');
        } on PlatformException catch (error) {
          debugPrint('pip: dispose failed: $error');
        }
      }
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _pushLayout() async {
    if (!isAvailable || !_enabled) return;
    try {
      await _channel.invokeMethod<void>('setLayout', <String, Object>{
        'layout': _layout.name,
        'quarterTurns': _quarterTurns,
      });
    } on PlatformException catch (error) {
      debugPrint('pip: setLayout failed: $error');
    }
  }

  void _restartPump() {
    _pump?.cancel();
    if (!_enabled || _disposed) return;
    final interval = _active || !_foreground ? _activeInterval : _idleInterval;
    _pump = Timer.periodic(interval, (_) => _tick());
  }

  void _tick() {
    if (!_dirty || _inFlight || !_enabled) return;
    if (_top == null && _bottom == null) return;
    _dirty = false;
    _inFlight = true;
    unawaited(
      _channel
          .invokeMethod<void>('pushFrames', <String, Object?>{
            'top': _top,
            'bottom': _bottom,
          })
          .catchError((Object error) {
            debugPrint('pip: pushFrames failed: $error');
          })
          .whenComplete(() => _inFlight = false),
    );
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onActiveChanged':
        _setActive(call.arguments as bool? ?? false);
      case 'onFailed':
        _lastError = call.arguments as String?;
        _setActive(false);
      case 'onRestoreUi':
        // The Flutter tree stayed mounted the whole time; nothing to rebuild.
        break;
    }
    return null;
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    if (value) _lastError = null;
    _restartPump();
  }
}
