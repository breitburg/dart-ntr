import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ntr/ntr.dart';

import 'view_options.dart';

/// Connects to a 3DS, performs the Remote Play handshake, and renders the
/// two screens as they stream in. No persistent chrome — a long press
/// anywhere opens the options sheet (view + stream settings + disconnect).
class StreamingPage extends StatefulWidget {
  const StreamingPage({super.key, required this.ipAddress});

  final String ipAddress;

  @override
  State<StreamingPage> createState() => _StreamingPageState();
}

class _StreamingPageState extends State<StreamingPage> {
  late NtrConfig _streamConfig = NtrConfig(ipAddress: widget.ipAddress);
  NtrSession? _session;
  StreamSubscription<ScreenFrame>? _framesSubscription;
  Uint8List? _topJpeg;
  Uint8List? _bottomJpeg;
  ViewOptions _viewOptions = const ViewOptions();
  String _status = 'Connecting…';
  Object? _error;
  bool _busy = false;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(_connect());
  }

  @override
  void dispose() {
    unawaited(_framesSubscription?.cancel());
    unawaited(_session?.dispose());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Negotiating Remote Play…';
    });
    try {
      final session = NtrSession(_streamConfig);
      _session = session;
      _framesSubscription = session.frames.listen(
        (frame) {
          if (!mounted) return;
          setState(() {
            if (frame.screen == Screen.top) {
              _topJpeg = frame.jpeg;
            } else {
              _bottomJpeg = frame.jpeg;
            }
          });
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _error = error;
            _status = 'Stream error';
          });
        },
      );
      await session.startStreaming();
      if (!mounted) return;
      setState(() {
        _status = 'Streaming';
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _status = 'Connection failed';
        _busy = false;
      });
    }
  }

  Future<void> _applyStreamConfig(NtrConfig next) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _streamConfig = next;
      _status = 'Reconnecting with new settings…';
    });
    try {
      final session = _session;
      if (session != null) {
        await session.stopStreaming();
        session.updateConfig(next);
        await session.startStreaming();
      } else {
        await _connect();
        return;
      }
      if (!mounted) return;
      setState(() {
        _status = 'Streaming';
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _status = 'Reconnect failed';
        _busy = false;
      });
    }
  }

  Future<void> _openMenu() async {
    if (_menuOpen) return;
    _menuOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return _OptionsSheet(
          ipAddress: widget.ipAddress,
          status: _status,
          busy: _busy,
          viewOptions: _viewOptions,
          streamConfig: _streamConfig,
          onViewChanged: (next) {
            if (mounted) setState(() => _viewOptions = next);
          },
          onApplyStream: (next) {
            Navigator.of(sheetContext).pop();
            unawaited(_applyStreamConfig(next));
          },
          onDisconnect: () {
            Navigator.of(sheetContext).pop();
            Navigator.of(context).pop();
          },
        );
      },
    );
    _menuOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: _openMenu,
        onSecondaryTap: _openMenu,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _CenteredMessage(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: 'Connection failed',
        detail: '$_error',
        action: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
      );
    }
    if (_topJpeg == null && _bottomJpeg == null) {
      return _CenteredMessage(
        title: _status,
        detail:
            'Long press anywhere once streaming starts to change view options, '
            'stream settings, or disconnect.',
        spinner: true,
      );
    }
    return _ScreensLayout(
      topJpeg: _topJpeg,
      bottomJpeg: _bottomJpeg,
      options: _viewOptions,
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    this.icon,
    required this.title,
    this.detail,
    this.action,
    this.spinner = false,
  });

  final IconData? icon;
  final String title;
  final String? detail;
  final Widget? action;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (spinner)
              const CupertinoActivityIndicator(color: Colors.white, radius: 14)
            else if (icon != null)
              Icon(icon, color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            if (detail != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ScreensLayout extends StatelessWidget {
  const _ScreensLayout({
    required this.topJpeg,
    required this.bottomJpeg,
    required this.options,
  });

  final Uint8List? topJpeg;
  final Uint8List? bottomJpeg;
  final ViewOptions options;

  @override
  Widget build(BuildContext context) {
    final top = _screen(topJpeg, isTop: true);
    final bottom = _screen(bottomJpeg, isTop: false);
    return switch (options.layout) {
      ScreenLayout.stacked => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: top),
            Expanded(child: bottom),
          ],
        ),
      ScreenLayout.sideBySide => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: top),
            Expanded(child: bottom),
          ],
        ),
      ScreenLayout.topOnly => top,
      ScreenLayout.bottomOnly => bottom,
    };
  }

  Widget _screen(Uint8List? jpeg, {required bool isTop}) {
    if (jpeg == null) {
      return const SizedBox.shrink();
    }
    // The device sends frames rotated 90°: the decoded JPEG is portrait,
    // top 240x400, bottom 240x320. After applying [quarterTurns] the visible
    // aspect flips for odd rotations, so the outer AspectRatio needs to
    // match the *post-rotation* shape — otherwise BoxFit letterboxes inside
    // a too-tall box.
    final naturalAspect = isTop ? 240 / 400 : 240 / 320;
    final displayedAspect = options.quarterTurns.isOdd
        ? 1 / naturalAspect
        : naturalAspect;
    return Center(
      child: AspectRatio(
        aspectRatio: displayedAspect,
        child: RotatedBox(
          quarterTurns: options.quarterTurns,
          child: Image.memory(
            jpeg,
            gaplessPlayback: true,
            fit: BoxFit.fill,
            filterQuality:
                options.smoothing ? FilterQuality.medium : FilterQuality.none,
          ),
        ),
      ),
    );
  }
}

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({
    required this.ipAddress,
    required this.status,
    required this.busy,
    required this.viewOptions,
    required this.streamConfig,
    required this.onViewChanged,
    required this.onApplyStream,
    required this.onDisconnect,
  });

  final String ipAddress;
  final String status;
  final bool busy;
  final ViewOptions viewOptions;
  final NtrConfig streamConfig;
  final ValueChanged<ViewOptions> onViewChanged;
  final ValueChanged<NtrConfig> onApplyStream;
  final VoidCallback onDisconnect;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late ViewOptions _view = widget.viewOptions;
  late int _jpegQuality = widget.streamConfig.jpegQuality;
  late int _priorityMode = widget.streamConfig.priorityMode;
  late int _priorityFactor = widget.streamConfig.priorityFactor;
  late int _qosValue = widget.streamConfig.qosValue;

  bool get _streamDirty {
    final base = widget.streamConfig;
    return _jpegQuality != base.jpegQuality ||
        _priorityMode != base.priorityMode ||
        _priorityFactor != base.priorityFactor ||
        _qosValue != base.qosValue;
  }

  NtrConfig get _pendingConfig => widget.streamConfig.copyWith(
        jpegQuality: _jpegQuality,
        priorityMode: _priorityMode,
        priorityFactor: _priorityFactor,
        qosValue: _qosValue,
      );

  void _emitView(ViewOptions next) {
    setState(() => _view = next);
    widget.onViewChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _header(),
              const SizedBox(height: 24),
              const _SectionLabel('View'),
              const SizedBox(height: 8),
              _layoutPicker(),
              const SizedBox(height: 16),
              _rotationPicker(),
              const SizedBox(height: 4),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Smoothing',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Bilinear filter when scaling',
                  style: TextStyle(color: Colors.white54),
                ),
                value: _view.smoothing,
                onChanged: (value) =>
                    _emitView(_view.copyWith(smoothing: value)),
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Stream'),
              const SizedBox(height: 12),
              _slider(
                label: 'JPEG quality',
                hint: 'Higher = sharper, more bandwidth',
                value: _jpegQuality.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                display: '$_jpegQuality',
                onChanged: (value) =>
                    setState(() => _jpegQuality = value.round()),
              ),
              const SizedBox(height: 16),
              _priorityModePicker(),
              const SizedBox(height: 16),
              _slider(
                label: 'Priority factor',
                hint: 'Strength of the priority above (0 = off)',
                value: _priorityFactor.toDouble(),
                min: 0,
                max: 15,
                divisions: 15,
                display: '$_priorityFactor',
                onChanged: (value) =>
                    setState(() => _priorityFactor = value.round()),
              ),
              const SizedBox(height: 16),
              _slider(
                label: 'QoS (bandwidth)',
                hint: 'Upper bound on the device\'s outgoing rate',
                value: _qosValue.toDouble(),
                min: 10,
                max: 127,
                divisions: 117,
                display: '$_qosValue',
                onChanged: (value) =>
                    setState(() => _qosValue = value.round()),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: widget.busy || !_streamDirty
                    ? null
                    : () => widget.onApplyStream(_pendingConfig),
                icon: const Icon(Icons.refresh),
                label: Text(
                  _streamDirty
                      ? 'Apply and reconnect'
                      : 'Stream settings up to date',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.ipAddress,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.status,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: widget.onDisconnect,
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Disconnect'),
        ),
      ],
    );
  }

  Widget _layoutPicker() {
    return SegmentedButton<ScreenLayout>(
      segments: const <ButtonSegment<ScreenLayout>>[
        ButtonSegment(
          value: ScreenLayout.stacked,
          icon: Icon(Icons.view_agenda_outlined),
          label: Text('Stack'),
        ),
        ButtonSegment(
          value: ScreenLayout.sideBySide,
          icon: Icon(Icons.view_column_outlined),
          label: Text('Side'),
        ),
        ButtonSegment(
          value: ScreenLayout.topOnly,
          icon: Icon(Icons.crop_landscape),
          label: Text('Top'),
        ),
        ButtonSegment(
          value: ScreenLayout.bottomOnly,
          icon: Icon(Icons.crop_square),
          label: Text('Bottom'),
        ),
      ],
      selected: <ScreenLayout>{_view.layout},
      onSelectionChanged: (selection) =>
          _emitView(_view.copyWith(layout: selection.first)),
    );
  }

  Widget _rotationPicker() {
    return Row(
      children: <Widget>[
        const Expanded(
          child: Text('Rotation', style: TextStyle(color: Colors.white)),
        ),
        IconButton.filledTonal(
          icon: const Icon(Icons.rotate_left),
          onPressed: () => _emitView(_view.copyWith(
            quarterTurns: (_view.quarterTurns + 3) % 4,
          )),
        ),
        SizedBox(
          width: 56,
          child: Center(
            child: Text(
              '${_view.quarterTurns * 90}°',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          icon: const Icon(Icons.rotate_right),
          onPressed: () => _emitView(_view.copyWith(
            quarterTurns: (_view.quarterTurns + 1) % 4,
          )),
        ),
      ],
    );
  }

  Widget _priorityModePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Priority', style: TextStyle(color: Colors.white)),
        const SizedBox(height: 2),
        const Text(
          'Which screen the device should favour',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const <ButtonSegment<int>>[
            ButtonSegment(value: 0, label: Text('Bottom')),
            ButtonSegment(value: 1, label: Text('Top')),
            ButtonSegment(value: 2, label: Text('Neither')),
          ],
          selected: <int>{_priorityMode},
          onSelectionChanged: (selection) =>
              setState(() => _priorityMode = selection.first),
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(label, style: const TextStyle(color: Colors.white)),
            ),
            Text(
              display,
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Text(
          hint,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
