import '../network/keep_alive.dart';
import '../network/reconnect_policy.dart';
import '../webrtc/ice_config.dart';
import '../webrtc/media_constraints.dart';

// For dartdoc references only.
import '../errors/vobiz_exception.dart' show VobizDemoModeRequiredException;

/// Configuration for [VobizClient].
///
/// No credentials are part of the configuration, and the account Auth Token
/// never belongs on a device. In production your own backend hands each
/// signed-in user their own SIP endpoint's credentials (see CREDENTIALS.md):
///
/// ```dart
/// final client = VobizClient(config: const SdkConfig());
///
/// // Production: per-user SIP credentials from your backend, re-fetched
/// // whenever the registrar refuses them.
/// await client.connectWithCredentialsProvider(myBackendProvider);
///
/// // Or SIP Direct: an endpoint's username and password you already hold.
/// await client.connectWithCredentials(
///   CredentialConfig(username: sipUsername, password: sipPassword),
/// );
/// ```
///
/// Zero-Config Setup (`connectWithAuthToken`) sends the account Auth ID and
/// Auth Token to the webhook server, exactly like the web Playground. It is a
/// demo and refuses to run unless [unsafeDemoZeroConfig] is true.
class SdkConfig {
  const SdkConfig({
    this.wsUrl = 'wss://registrar.vobiz.ai:5063/',
    this.sipServer = 'registrar.vobiz.ai',
    this.backendUrl = defaultWebhookUrl,
    this.voiceApiUrl = defaultVoiceApiUrl,
    this.answerUrl,
    this.autoReconnect = true,
    this.debug = false,
    this.iceConfig = const IceConfig(),
    this.mediaConstraints = const MediaConstraints(),
    this.unsafeDemoZeroConfig = false,
    this.reconnectPolicy = const ReconnectPolicy(),
    this.keepAlive = const KeepAliveConfig(),
    this.watchNetwork = true,
    this.reregisterOnForeground = true,
  });

  /// The hosted Vobiz WebRTC Playground server: the "production webhook
  /// callback" the web Playground uses.
  static const String defaultWebhookUrl = 'https://rtc-demo.vobiz.ai';

  /// The Vobiz REST API.
  static const String defaultVoiceApiUrl = 'https://api.vobiz.ai';

  /// WebSocket URL of the Vobiz SIP registrar.
  final String wsUrl;

  /// SIP server domain used in SIP `From`/`To`/`Contact` headers.
  final String sipServer;

  /// Public base URL of the webhook (answer URL) server.
  ///
  /// The default, [defaultWebhookUrl], is the shared Vobiz demo server. It is
  /// only used in demo mode ([unsafeDemoZeroConfig]): its recordings list is
  /// shared by everyone who uses it, so the SDK will not read it otherwise.
  /// Production apps that use transfers or recordings set this to their own
  /// server.
  ///
  /// Zero-Config Setup points the account's application at `<backendUrl>/api/answer`,
  /// so Vobiz must be able to reach it over HTTPS. Transfers and the recordings
  /// list also go through it. Defaults to [defaultWebhookUrl]; point it at your
  /// own deployment of the Playground server (or a tunnel to it while
  /// developing) to use your own.
  ///
  /// The legacy call-control methods (`hold`, `resume`, `transfer(String)`,
  /// `addCall`, `swapCalls`, `mergeCalls` and friends) call routes such as
  /// `/hold-start` on this same URL. Only the Node reference server
  /// implements those; the Playground server does not.
  final String backendUrl;

  /// The Vobiz REST API base URL that the webhook server calls on the
  /// account's behalf. Defaults to [defaultVoiceApiUrl].
  final String voiceApiUrl;

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

  /// DEMO ONLY. Allows the operations that send the account Auth ID and Auth
  /// Token from the device: Zero-Config Setup (`connectWithAuthToken`), the
  /// Playground transfer (`transferCall`) and reading the shared Playground
  /// recordings list on [defaultWebhookUrl].
  ///
  /// The Auth Token is the account's full REST credential (buy numbers, place
  /// calls, read CDRs). Zero-Config also uses one shared endpoint per account
  /// and gives it a new password on every sign-in, so two devices signed in
  /// to the same account log each other out. Never ship an app with this set.
  ///
  /// Defaults to false; the operations above then throw
  /// [VobizDemoModeRequiredException].
  final bool unsafeDemoZeroConfig;

  /// Backoff and retry cap for [autoReconnect].
  ///
  /// Defaults to 1 s doubling to 30 s, giving up after 10 attempts with a
  /// `reconnect_failed` error and [ConnectionStateStatus.failed]. The client
  /// tries again when the network changes or the app calls
  /// `VobizClient.reconnect()`.
  final ReconnectPolicy reconnectPolicy;

  /// How the signalling WebSocket is kept open and how fast a dead one is
  /// noticed. Defaults to a WebSocket ping every 15 s (dead within 30 s).
  final KeepAliveConfig keepAlive;

  /// Watch the device's network (Wi-Fi, mobile, offline) and react at once:
  /// fail calls fast while offline, and reconnect and re-register as soon as
  /// the network comes back or changes. Without it a lost network is noticed
  /// only by the keep-alive.
  final bool watchNetwork;

  /// Register again each time the app returns to the foreground, so Vobiz
  /// has the device's current address: a phone's IP often changes while it
  /// is locked or the app is in the background. On a live connection this is
  /// one REGISTER on the same socket (a call in progress is not touched); a
  /// dead or failed connection is reconnected at once with the backoff reset.
  /// Nothing happens while signed out, and repeated resumes within 2 s count
  /// as one.
  final bool reregisterOnForeground;
}
