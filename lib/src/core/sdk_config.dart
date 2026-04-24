import '../webrtc/ice_config.dart';
import '../webrtc/media_constraints.dart';

class SdkConfig {
  const SdkConfig({
    this.wsUrl = 'wss://registrar.vobiz.ai:5063/',
    this.sipServer = 'registrar.vobiz.ai',
    this.backendUrl = 'http://127.0.0.1:3000',
    this.autoReconnect = true,
    this.debug = false,
    this.iceConfig = const IceConfig(),
    this.mediaConstraints = const MediaConstraints(),
  });

  /// WebSocket URL of the Vobiz SIP registrar.
  final String wsUrl;

  /// SIP server domain (used in SIP headers).
  final String sipServer;

  /// Base URL of your Vobiz backend server (Node.js demo server).
  /// Used for inbound call polling and call control (hold, transfer, etc.).
  final String backendUrl;

  final bool autoReconnect;
  final bool debug;
  final IceConfig iceConfig;
  final MediaConstraints mediaConstraints;
}
