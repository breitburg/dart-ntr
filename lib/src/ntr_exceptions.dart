/// Base class for every error raised by the `ntr` package.
///
/// Sealed so callers can `switch` exhaustively on the concrete subtypes.
sealed class NtrException implements Exception {
  /// Creates an exception with a human-readable [message].
  const NtrException(this.message);

  /// Human-readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The TCP control socket failed to connect or was lost mid-session.
final class NtrConnectionException extends NtrException {
  /// Creates a connection error with the given [message].
  const NtrConnectionException(super.message);
}

/// An operation did not complete within the expected window.
final class NtrTimeoutException extends NtrException {
  /// Creates a timeout error with the given [message].
  const NtrTimeoutException(super.message);
}

/// The peer sent bytes that do not conform to the NTR wire protocol
/// (bad magic number, malformed JPEG frame, bad packet sequence).
final class NtrProtocolException extends NtrException {
  /// Creates a protocol error with the given [message].
  const NtrProtocolException(super.message);
}
