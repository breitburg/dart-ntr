import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ntr/ntr.dart';

import 'view_options.dart';

/// Connects to a 3DS, performs the Remote Play handshake, and renders the
/// two screens as they stream in. No persistent chrome — a long press
/// anywhere opens the options sheet (where you can also disconnect).
class StreamingPage extends StatefulWidget {
  const StreamingPage({super.key, required this.ipAddress});

  final String ipAddress;

  @override
  State<StreamingPage> createState() => _StreamingPageState();
}

class _StreamingPageState extends State<StreamingPage> {
  NtrSession? _session;
  StreamSubscription<ScreenFrame>? _framesSubscription;
  Uint8List? _topJpeg;
  Uint8List? _bottomJpeg;
  ViewOptions _options = const ViewOptions();
  String _status = 'Connecting…';
  Object? _error;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_framesSubscription?.cancel());
    unawaited(_session?.dispose());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = NtrSession(NtrConfig(ipAddress: widget.ipAddress));
      _session = session;
      setState(() => _status = 'Negotiating Remote Play…');
      await session.startStreaming();
      setState(() => _status = 'Streaming');
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _status = 'Connection failed';
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
          options: _options,
          status: _status,
          ipAddress: widget.ipAddress,
          onChanged: (next) {
            if (mounted) setState(() => _options = next);
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
            'Long press anywhere once streaming starts to change view options or disconnect.',
        spinner: true,
      );
    }
    return _ScreensLayout(
      topJpeg: _topJpeg,
      bottomJpeg: _bottomJpeg,
      options: _options,
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
    required this.options,
    required this.status,
    required this.ipAddress,
    required this.onChanged,
    required this.onDisconnect,
  });

  final ViewOptions options;
  final String status;
  final String ipAddress;
  final ValueChanged<ViewOptions> onChanged;
  final VoidCallback onDisconnect;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late ViewOptions _options = widget.options;

  void _emit(ViewOptions next) {
    setState(() => _options = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
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
            Row(
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
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const _SectionLabel('Layout'),
            const SizedBox(height: 8),
            SegmentedButton<ScreenLayout>(
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
              selected: <ScreenLayout>{_options.layout},
              onSelectionChanged: (selection) =>
                  _emit(_options.copyWith(layout: selection.first)),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('Rotation'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                IconButton.filledTonal(
                  icon: const Icon(Icons.rotate_left),
                  onPressed: () => _emit(_options.copyWith(
                    quarterTurns: (_options.quarterTurns + 3) % 4,
                  )),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_options.quarterTurns * 90}°',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.rotate_right),
                  onPressed: () => _emit(_options.copyWith(
                    quarterTurns: (_options.quarterTurns + 1) % 4,
                  )),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
              value: _options.smoothing,
              onChanged: (value) =>
                  _emit(_options.copyWith(smoothing: value)),
            ),
          ],
        ),
      ),
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
