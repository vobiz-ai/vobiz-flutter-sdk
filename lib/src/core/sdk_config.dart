import '../webrtc/ice_config.dart';
import '../webrtc/media_constraints.dart';

/// Configuration for [VobizClient].
///
/// Pass an instance to [VobizClient] at construction time. All fields have
/// sensible defaults so you only need to supply the values that differ from
/// the standard Vobiz setup.
///
/// ```dart
/// final client = VobizClient(
///   config: SdkConfig(
///     wsUrl: 'wss://registrar.vobiz.ai:5063/',
///     sipServer: 'registrar.vobiz.ai',
///     backendUrl: 'https://your-server.example.com',
///   ),
/// );
/// ```
class SdkConfig {
  const SdkConfig({
    this.wsUrl = 'wss://registrar.vobiz.ai:5063/',
    this.sipServer = 'registrar.vobiz.ai',
    this.backendUrl = 'https://rtc-demo.vobiz.ai',
    this.answerUrl,
    this.autoReconnect = true,
    this.debug = false,
    this.iceConfig = const IceConfig(),
    this.mediaConstraints = const MediaConstraints(),
  });

  /// WebSocket URL of the Vobiz SIP registrar.
  final String wsUrl;

  /// SIP server domain used in SIP `From`/`To`/`Contact` headers.
  final String sipServer;

  /// Base URL of your Vobiz webhook server.
  ///
  /// Used for inbound call polling (`GET /pending-call`) and call control
  /// (`/hold-start`, `/resume`, `/transfer`, `/add-call`, etc.).
  /// On Android emulator use `http://10.0.2.2:3000` to reach the host machine.
  final String backendUrl;

  /// Public answer webhook URL sent to Vobiz during login.
  ///
  /// Vobiz calls this URL when routing an inbound PSTN call to this client.
  /// Must be publicly reachable (e.g. your ngrok URL + `/answer`).
  final String? answerUrl;

  /// Reconnect automatically when the WebSocket drops.
  final bool autoReconnect;

  /// Enable verbose SDK logging to the console.
  final bool debug;

  /// ICE/STUN/TURN server configuration.
  ///
  /// Defaults to Google's public STUN server. Supply your own TURN credentials
  /// for production deployments behind symmetric NAT.
  final IceConfig iceConfig;

  /// WebRTC media constraints passed to `getUserMedia`.
  ///
  /// Defaults to audio-only with echo cancellation, noise suppression and
  /// auto gain control enabled.
  final MediaConstraints mediaConstraints;
}
