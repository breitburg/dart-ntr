/// Immutable configuration for an [NtrSession].
///
/// Defaults match the values commonly used by NTR CFW Remote Play clients,
/// verified against the Qt cuteNTR reference client. Construct one, pass
/// it to a session, and use [copyWith] to tweak individual fields.
final class NtrConfig {
  /// Creates a configuration.
  const NtrConfig({
    required this.ipAddress,
    this.jpegQuality = 80,
    this.priorityMode = 1,
    this.priorityFactor = 5,
    this.qosValue = 105,
  });

  /// IPv4 address of the 3DS running NTR CFW.
  final String ipAddress;

  /// JPEG encoder quality on the device, `0..100`.
  final int jpegQuality;

  /// Which screen the device should prioritise (`0` bottom, `1` top, `2` both).
  final int priorityMode;

  /// How aggressively to prioritise the chosen screen, `0..15`.
  final int priorityFactor;

  /// Outgoing bandwidth budget. The wire field is `qosValue << 17`.
  final int qosValue;

  /// The four `uint32` arguments of the Remote Play (code 901) command.
  ///
  /// Encoding lives here so the wire format is defined in one place.
  List<int> get remotePlayArgs => <int>[
        (priorityMode << 8) | priorityFactor,
        jpegQuality,
        qosValue << 17,
        0,
      ];

  /// Returns a copy with the given fields overridden.
  NtrConfig copyWith({
    String? ipAddress,
    int? jpegQuality,
    int? priorityMode,
    int? priorityFactor,
    int? qosValue,
  }) {
    return NtrConfig(
      ipAddress: ipAddress ?? this.ipAddress,
      jpegQuality: jpegQuality ?? this.jpegQuality,
      priorityMode: priorityMode ?? this.priorityMode,
      priorityFactor: priorityFactor ?? this.priorityFactor,
      qosValue: qosValue ?? this.qosValue,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NtrConfig &&
        other.ipAddress == ipAddress &&
        other.jpegQuality == jpegQuality &&
        other.priorityMode == priorityMode &&
        other.priorityFactor == priorityFactor &&
        other.qosValue == qosValue;
  }

  @override
  int get hashCode => Object.hash(
        ipAddress,
        jpegQuality,
        priorityMode,
        priorityFactor,
        qosValue,
      );

  @override
  String toString() => 'NtrConfig(ipAddress: $ipAddress, '
      'jpegQuality: $jpegQuality, priorityMode: $priorityMode, '
      'priorityFactor: $priorityFactor, qosValue: $qosValue)';
}
