import 'package:flutter/foundation.dart';

/// How the two 3DS screens are laid out in the viewer.
enum ScreenLayout {
  /// Top above bottom (closest to the physical device).
  stacked,

  /// Top and bottom shown side by side.
  sideBySide,

  /// Only the top screen.
  topOnly,

  /// Only the bottom screen.
  bottomOnly,
}

/// User-tweakable rendering options for the streaming view.
@immutable
class ViewOptions {
  const ViewOptions({
    this.layout = ScreenLayout.stacked,
    this.quarterTurns = 3,
    this.smoothing = true,
  });

  final ScreenLayout layout;

  /// Frames are delivered rotated 90° — `1` is the natural orientation.
  final int quarterTurns;

  /// When true the JPEG is bilinearly filtered; when false it is nearest.
  final bool smoothing;

  ViewOptions copyWith({
    ScreenLayout? layout,
    int? quarterTurns,
    bool? smoothing,
  }) {
    return ViewOptions(
      layout: layout ?? this.layout,
      quarterTurns: quarterTurns ?? this.quarterTurns,
      smoothing: smoothing ?? this.smoothing,
    );
  }
}
