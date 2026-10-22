/// Make and receive Vobiz calls from Flutter: SIP over WebSocket for
/// signalling, WebRTC for audio.
///
/// Start with [VobizClient]. Sign in with per-user SIP credentials from your
/// own backend ([VobizClientCredentialsProvider.connectWithCredentialsProvider]);
/// the account Auth Token never belongs on a device.
library vobiz_webrtc;

// ── Core ──────────────────────────────────────────────────────────────────────
export 'src/core/sdk_config.dart';
export 'src/core/sip_headers.dart';
export 'src/core/vobiz_client.dart';
export 'src/errors/vobiz_exception.dart';
export 'src/utils/logger.dart' show Logger, LogWriter;

// ── Configuration ─────────────────────────────────────────────────────────────
export 'src/webrtc/ice_config.dart';
export 'src/webrtc/media_constraints.dart';

// ── Network ───────────────────────────────────────────────────────────────────
export 'src/network/app_lifecycle_monitor.dart';
export 'src/network/connectivity_monitor.dart';
export 'src/network/keep_alive.dart' show KeepAliveConfig;
export 'src/network/network_event.dart';
export 'src/network/reconnect_policy.dart';
export 'src/network/turn_servers.dart';
// ── Media and audio ───────────────────────────────────────────────────────────
export 'src/audio/audio_route.dart'
    show AudioRoute, AudioRouteDevice, AudioRouteController, BluetoothPermissionRequester;
export 'src/audio/proximity.dart' show ProximityController, NoProximityController;
export 'src/media/call_media_event.dart';
export 'src/media/call_quality.dart' show CallQualityLevel, CallQualitySample;
export 'src/media/dtmf_transport.dart';

// ── Authentication ────────────────────────────────────────────────────────────
export 'src/auth/credentials_provider.dart';
export 'src/backend/backend_credentials_provider.dart';
export 'src/models/auth/auth_mode.dart';
export 'src/models/auth/credential_config.dart';
export 'src/models/auth/token_config.dart';
export 'src/models/auth/zero_config_session.dart';

// ── Calls ─────────────────────────────────────────────────────────────────────
export 'src/calls/call_actions.dart';
export 'src/calls/call_session.dart';

// ── Push ──────────────────────────────────────────────────────────────────────
export 'src/push/vobiz_push.dart';

// ── Events ────────────────────────────────────────────────────────────────────
export 'src/events/call_event.dart';
export 'src/events/connection_event.dart';
export 'src/events/error_event.dart';
export 'src/events/media_event.dart';
export 'src/events/sdk_event.dart';

// ── Models ────────────────────────────────────────────────────────────────────
export 'src/models/call/call_direction.dart';
export 'src/models/call/call_stats.dart';
export 'src/models/call/dtmf_tone.dart';
export 'src/models/call/incoming_call.dart';
export 'src/models/call/outgoing_call.dart';
export 'src/models/call/recording.dart';
export 'src/models/call/transfer_leg.dart';

// ── State ─────────────────────────────────────────────────────────────────────
export 'src/state/call_state.dart';
export 'src/state/connection_state.dart';
export 'src/state/registration_state.dart';
