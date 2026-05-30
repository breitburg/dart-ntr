import 'dart:typed_data';

/// Identifies which of the 3DS's two screens a frame belongs to.
enum Screen {
  /// The top (larger, widescreen) display.
  top,

  /// The bottom (touch) display.
  bottom,
}

/// A single fully-reassembled JPEG frame for one screen.
///
/// [jpeg] is the raw JPEG byte stream (`FF D8 … FF D9`), ready to hand to
/// a decoder such as Flutter's `Image.memory`.
final class ScreenFrame {
  /// Creates a frame for [screen] containing the JPEG bytes [jpeg].
  const ScreenFrame({required this.screen, required this.jpeg});

  /// Which screen this frame is for.
  final Screen screen;

  /// Raw JPEG bytes.
  final Uint8List jpeg;
}
