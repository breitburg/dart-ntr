/// Pure-Dart implementation of the NTR CFW protocol for the Nintendo 3DS:
/// TCP control channel, UDP screen streaming (Remote Play), and the
/// debugger / WriteMem surface.
///
/// Transport-only — the package emits raw JPEG bytes and exposes the
/// debugger commands; rendering and UI are left to the caller.
///
/// See [NtrSession] for the high-level entry point.
library;

export 'src/control_packet.dart'
    show ControlPacket, ntrPacketBytes, ntrPacketMagic;
export 'src/ntr_command.dart' show NtrCommand;
export 'src/ntr_config.dart' show NtrConfig;
export 'src/ntr_control_connection.dart'
    show NtrConnectionState, NtrControlConnection, NtrResponse;
export 'src/ntr_exceptions.dart'
    show
        NtrConnectionException,
        NtrException,
        NtrProtocolException,
        NtrTimeoutException;
export 'src/ntr_session.dart' show NtrSession;
export 'src/patches.dart' show Patch, Patches, findPidByName;
export 'src/screen_frame.dart' show Screen, ScreenFrame;
export 'src/screen_stream_receiver.dart' show ScreenStreamReceiver;
