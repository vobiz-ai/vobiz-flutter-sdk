# Vobiz WebRTC SDK for Flutter: API reference

Everything below is exported by `package:vobiz_webrtc/vobiz_webrtc.dart`.

- [VobizClient](#vobizclient): [signing in](#signing-in), [access tokens](#access-tokens-jwt),
  [calls](#calls), [audio](#audio-and-media), [transfer and recordings](#transfer-and-recordings-demo-only)
- [Incoming calls to a closed app (Vobiz push)](#incoming-calls-to-a-closed-app-vobiz-push)
- [VobizConference](#vobizconference)
- [Events](#events)
- [Network and reconnection](#network-and-reconnection)
- [Errors](#errors)
- [SdkConfig](#sdkconfig), [VobizSipHeaders](#vobizsipheaders), [Models](#models), [Enums](#enums)

## VobizClient

```dart
VobizClient({SdkConfig config = const SdkConfig(), Logger? logger, http.Client? httpClient,
    ConnectivityMonitor? connectivityMonitor, AppLifecycleMonitor? lifecycleMonitor})
```

`httpClient` is for tests; leave it out in an app. The two monitors default to the
platform (`PlatformConnectivityMonitor`, `PlatformAppLifecycleMonitor`); supply your own
to drive them from elsewhere or in tests.

### Signing in

| Method | Mode | Notes |
|---|---|---|
| `Future<VobizCredentialsSession> connectWithCredentialsProvider(VobizCredentialsProvider provider, {int maxRefreshes = 1})` | **Production** | Asks your provider for the user's SIP credentials and registers; asks again when the registrar refuses them. Throws `VobizCredentialsException` when the provider fails. See [CREDENTIALS.md](CREDENTIALS.md) |
| `Future<VobizAccessTokenSession> connectWithAccessTokenProvider(VobizAccessTokenProvider provider, {Duration refreshBefore = const Duration(seconds: 60), int maxRefreshes = 1})` | **Production**, access token | Asks your provider for an access token (JWT), registers with it, and keeps it fresh: see [Access tokens](#access-tokens-jwt). Throws `VobizAccessTokenException` when the provider fails or returns something that is not a Vobiz token |
| `Future<void> connectWithAccessToken(String accessToken)` | Access token | Registers as `<sub>_<iss>` with the token instead of a password. Not renewed: use the provider, or `updateAccessToken`. Throws `VobizAccessTokenException` (10001) for a token it cannot decode, one that is not base64url text, or one whose `sub` and `iss` do not make a SIP username |
| `Future<void> updateAccessToken(String accessToken)` | Access token | Registers again now with a fresh token for the same user, on the open socket; also recovers a refused sign-in. Throws `StateError` unless signed in with a token, `ArgumentError` for another user's token |
| `Future<void> connectWithCredentials(CredentialConfig config)` | SIP Direct | Registers as an existing endpoint. Throws `ArgumentError`, before touching the current connection, when the username is empty or holds a space, a line break or any of `< > " @` |
| `Future<ZeroConfigSession> connectWithAuthToken({required String authId, required String authToken})` | Zero-Config Setup, **demo only** | Throws `ArgumentError` when either value is blank, `VobizDemoModeRequiredException` unless `SdkConfig.unsafeDemoZeroConfig` is true, and `ArgumentError` when `backendUrl` is not `https` (plain `http` only to `localhost`, `127.0.0.1`, `::1` or the emulator's `10.0.2.2`). Then posts the Auth ID and Auth Token to `<backendUrl>/api/setup` and registers as the returned endpoint (whose password the server rotates). Throws `VobizException` (`setup_failed`) when refused |
| `Future<void> connect(Object credentials)` | SIP Direct, **deprecated** | Takes a `CredentialConfig`, or the deprecated `TokenConfig` (its token is sent as the SIP password; it is not token authentication) |
| `Future<void> disconnect({bool unregister = true})` | | Signs out. A call in progress is ended first (a ringing call is declined with 480, any other gets a BYE), then the client unregisters (REGISTER `Expires: 0`) and drops every credential. `unregister: false` closes the connection without unregistering, as when Android kills the app; it exists to test [Vobiz push](#incoming-calls-to-a-closed-app-vobiz-push) |
| `Future<void> dispose()` | | `disconnect()`, then closes the streams |
| `void reconnect()` | | Reconnects and registers now, resetting the backoff. For a "retry" button after `reconnect_failed`. Does nothing when signed out; while offline it waits for the network |

A new sign-in replaces the previous connection. Every sign-in completes once its
REGISTER is sent: watch `connectionEvents` for `RegistrationState.registered` or
`.failed`.

`connectWithCredentialsProvider` and `connectWithAccessTokenProvider` are extension
methods (`VobizClientCredentialsProvider`, `VobizClientAccessTokenProvider`). When the
socket cannot be opened they still return their session if the client retries the
connection by itself (`SdkConfig.autoReconnect`); the failure is reported on
`connectionEvents` and `errorEvents` (`connect_failed`). Dispose the session when the user
signs out; it does not disconnect the client. When the client is signed out (or signed
in another way) without disposing the session, the provider is not asked again and an
access-token session stops its renewal timers.

**Credentials provider.** `VobizCredentialsProvider` is
`Future<CredentialConfig> Function(VobizCredentialsRequest request)`, asked with
`signIn`, `rejected` (the registrar refused the last credentials) or `refresh`
(`session.refresh()`). After `maxRefreshes` refusals in a row the session reports a
`VobizRegistrationException` on `failures`. A refusal that comes during a call is
answered once the call has ended, because registering again opens a new connection.
`VobizCredentialsSession` has `client`, `maxRefreshes`, `failures` (a stream of
`VobizException`), `refresh()` (ends a call in progress: call it between calls) and
`dispose()`.

`VobizBackendCredentialsProvider(url:, headers:, httpClient:, timeout:)` is a ready-made
provider: it POSTs `{"reason": "sign_in" | "rejected" | "refresh"}` with your headers and
reads `{"sip_username", "sip_password"}`; anything else in the reply is ignored. Pass
`provider.call`.

| Getter | Meaning |
|---|---|
| `VobizAuthMode authMode` | `none`, `zeroConfig`, `sipDirect` or `accessToken` |
| `String? sipUsername` | The SIP user this client registers as: the endpoint, or `<sub>_<iss>` for an access token |
| `VobizAccessToken? accessToken` | The access token signed in with. Null for other sign-ins |
| `Duration? accessTokenTimeLeft` | How long the registrar said the token had left at the last successful REGISTER (its clock, not the device's) |
| `bool isConnected` | Socket connected and registered |
| `RegistrationState registrationState`, `ConnectionStateStatus connectionState` | |
| `NetworkStatus? network`, `SignalingQuality signalingQuality` | See [Network and reconnection](#network-and-reconnection) |
| `String backendUrl` | The webhook server. Mutable: set it before signing in to use another one |
| `static const String sdkVersion` | `0.2.0`: the version this SDK reports to Vobiz's push service |

### Access tokens (JWT)

Your backend mints the token with `POST /api/v1/Account/{auth_id}/JWT/Token/`, using
the account Auth ID and Auth Token, which stay on the server. Its claims:
`{"iss": "<auth_id>", "sub": "<your user id>", "nbf": <s>, "exp": <s>, "app": "<application id>",
"per": {"voice": {"incoming_allow": true, "outgoing_allow": true}}}`. See
[CREDENTIALS.md](CREDENTIALS.md#access-tokens-jwt).

- **Identity.** The client registers as `<sub>_<iss>`: no endpoint has to exist in the
  Console. To ring the user, dial `<User>sip:<sub>_<iss>@registrar.vobiz.ai</User>`.
- **On the wire.** Every REGISTER and every outbound INVITE carries `X-Vobiz-Jwt: <token>`
  instead of answering a digest challenge. The token's `app` claim picks the application
  whose Answer URL handles outbound calls. The SDK never logs the token.
- **Grants.** `makeCall` throws `VobizAccessTokenException` (10008
  `INVALID_ACCESS_TOKEN_GRANTS`) unless `per.voice.outgoing_allow` is true, before
  anything is sent. The SDK does not check `incoming_allow`.
- **Renewal.** The provider session asks for the next token (`expiring`) `refreshBefore`
  (60 s) ahead of the current token's expiry and registers with it on the same socket,
  without touching a call. Once the registrar has accepted a token, that expiry is timed
  by the registrar's own count (`accessTokenTimeLeft`), so a phone whose clock is wrong
  still renews in time; before that, by the device's clock. A token that arrives with
  less than `refreshBefore` left is renewed after 5 s, then twice as long for each such
  token in a row, up to 60 s. With `connectWithAccessToken` alone, call
  `updateAccessToken` yourself.
- **Failures.** When the provider fails, or the token it returns cannot be presented,
  the session asks again after `firstRetryDelay` (5 s), doubling the wait up to
  `maximumRetryDelay` (60 s), and reports each failure on `failures`. It stops for a
  token that belongs to another user.
- **Refusals.** A refused REGISTER fails the registration: an `ErrorEvent` with code
  `registration_failed` whose `cause` is a `VobizAccessTokenException` carrying the
  registrar's `X-vobiz-Jwt-Error-Code`. A refused INVITE fails the call with the same
  name in its reason. The provider session then asks for a new token (`rejected`),
  except for 10005 `ACCESS_TOKEN_NOT_VALID_YET`, where it presents the same token again
  after `notValidYetRetryDelay` (3 s). After `maxRefreshes` refusals in a row it gives up
  and reports it on `failures`.

| `tokenError` | `tokenErrorName` | Meaning |
|---|---|---|
| 10001 | `INVALID_ACCESS_TOKEN` | Not a JWT, or a claim is missing or has the wrong type |
| 10002 | `INVALID_ACCESS_TOKEN_HEADER` | `typ`, `alg` or `cty` is not what Vobiz signs |
| 10003 | `INVALID_ACCESS_TOKEN_ISSUER` | `iss` is not a known Auth ID |
| 10004 | `INVALID_ACCESS_TOKEN_SUBJECT` | `sub` names no identity on that account |
| 10005 | `ACCESS_TOKEN_NOT_VALID_YET` | `nbf` is in the future |
| 10006 | `ACCESS_TOKEN_EXPIRED` | `exp` has passed |
| 10007 | `INVALID_ACCESS_TOKEN_SIGNATURE` | Not signed with the account's Auth Token |
| 10008 | `INVALID_ACCESS_TOKEN_GRANTS` | `per.voice` does not allow it |
| 10009 | `EXPIRATION_EXCEEDS_MAX_ALLOWED_TIME` | `exp - nbf` is outside 180 s to 24 h |
| 10010 | `MAX_ALLOWED_LOGIN_REACHED` | Too many sign-ins for this identity |

`VobizAccessTokenProvider` is `Future<String> Function(VobizAccessTokenRequest request)`,
asked with `signIn`, `expiring`, `rejected` or `refresh` (`session.refresh()`).
`VobizAccessTokenSession` has `client`, `refreshBefore`, `maxRefreshes`, `nextRefreshAt`
(the next renewal or retry; null when nothing is scheduled), `failures`, `refresh()` and
`dispose()`, and the constants `minimumRefreshDelay` (5 s), `firstRetryDelay` (5 s),
`maximumRetryDelay` (60 s) and `notValidYetRetryDelay` (3 s).
`VobizBackendAccessTokenProvider(url:, headers:, httpClient:, timeout:)` POSTs
`{"reason": "sign_in" | "expiring" | "rejected" | "refresh"}` to your backend and reads
`{"token": ...}`; pass `provider.call`.

### Calls

```dart
Future<String> makeCall(
  String destination, {        // E.164, such as +919876543210
  String? callerId,            // a plus and 7 to 15 digits; sent as X-VH-Caller-ID
  Map<String, String> headers = const {},  // custom X-VH- headers
  bool record = false,         // X-VH-Record: true
  String? dialUser,            // X-VH-DialUser: ring this endpoint instead
})
```

Returns the client's call ID. Throws `StateError` while offline, when not registered or
when already in a call; `VobizAccessTokenException` (10008) when the access token does
not allow outgoing calls; and `ArgumentError`, before anything is dialled, naming every
invalid header, a caller ID that is not a plus and 7 to 15 digits, or a destination with
a space, a line break or any of `" < > @ ; : ? ,`.

| Method | Notes |
|---|---|
| `Future<void> acceptCall([String? callId])` | Answers the ringing incoming call. Does nothing when no call is ringing, or when `callId` is given and is not the ringing call's |
| `Future<void> rejectCall([String? callId])` | Declines a ringing call with 486 Busy Here; on an answered call, hangs up with a BYE |
| `Future<void> hangup([String? callId])` | Ends the call |
| `Future<void> mute([String? callId])`, `unmute(...)` | Microphone. Asked while the call is connecting, it applies once the microphone opens; it survives hold and resume; a new call starts unmuted. Does nothing for another call's id |
| `Future<void> setSpeakerphone(bool enabled)` | Loudspeaker, or back to the earpiece or a connected headset. Each call starts off the loudspeaker |
| `Future<void> sendDtmf(String digits, {DtmfTransport transport = DtmfTransport.auto})` | `0-9 * # A-D`. `auto`: RFC 4733 telephone-events in the audio when the call negotiated `telephone-event`, otherwise one SIP INFO (`application/dtmf-relay`) per digit, 500 ms apart. `rfc4733` throws `StateError` when it was not negotiated; `sipInfo` always sends INFO. `StateError` without a connected call |
| `Future<void> hold([String? callId])`, `resume(...)` | A re-INVITE with `a=sendonly` (hold) or `a=sendrecv` (resume): the far end hears hold music. State `held` / `active`, and a `HoldChangedEvent`. Throws `StateError` without a connected (or held) call, and `VobizException` (`hold_failed` / `resume_failed`, with `statusCode`) when refused: the call carries on as it was, unless the refusal is a 481 (the far end no longer has the call), which ends it |
| `Future<void> audioInterruptionBegan()`, `audioInterruptionEnded({bool shouldResume = true})` | Another app's call took the microphone: holds the connected call, and resumes it afterwards unless the user had held it. The SDK cannot detect this itself; feed it from your audio-session events |
| `Future<CallStats?> getCallStats()` | `rttMs`, `jitterMs`, `packetLossPercent` from WebRTC stats; a field is null until measured; null without a call |
| `static Map<String, String> buildCallHeaders({...})` | What `makeCall` would send for these options, validated. For checking a form |
| `static String endpointUsername(String? value)` | `sip:play1@registrar.vobiz.ai` → `play1` |

| Getter | Meaning |
|---|---|
| `CallStateStatus callState` | `idle` between calls |
| `String? currentCallId` | The current call's ID |
| `CallSession? currentCall` | A snapshot of the current call, with the `actions` its state allows |
| `CallDirection? callDirection` | `inbound` or `outbound` |
| `String? callUuid` | Vobiz's CallUUID for this leg (the `X-Calluuid` header), once reported |
| `String? lastCallUuid` | The CallUUID of the most recent ended call |
| `Map<String, String> callHeaders` | Custom headers sent (outbound) or received (inbound) |
| `bool isMuted`, `bool isSpeakerOn` | |

### Audio and media

| Member | Notes |
|---|---|
| `Stream<CallMediaEvent> callMediaEvents` | `MuteChangedEvent` (`muted`), `HoldChangedEvent` (`held`), `EarlyMediaEvent` (183 with audio), `AudioRouteChangedEvent` (`route`) and `CallQualityEvent` (`sample`, `level`, `levelChanged`; every 2 s once media flows) |
| `AudioRouteController audioRoutes` | Call audio outputs, below |
| `ProximityController proximity` | Turns the screen off at the ear while a call is on the earpiece. The SDK has no platform code: set `ProximityController.fromCallback((enabled) => ...)` with your own platform call. Does nothing by default (`NoProximityController`) |
| `void updateIceConfig(IceConfig config)` | Replaces the STUN and TURN servers (fresh TURN credentials, say). Applies from the next call |

`AudioRouteController`: `currentRoute`, `isSpeakerOn`, `routeChanges` (a stream of
`AudioRoute`), `availableDevices()` (`AudioRouteDevice`: `route`, `deviceId`, `label`),
`availableRoutes()`, `selectRoute(AudioRoute)` (throws `StateError` when that output is
not connected, or for Bluetooth when the permission was refused), `setSpeakerOn(bool)`,
`reset()`, and `bluetoothPermissionRequester` (`Future<bool> Function()`): set it so a
Bluetooth headset is offered on Android 12+, which needs `BLUETOOTH_CONNECT` at run time.
The SDK asks once, before the first call's audio starts. `AudioRoute`: `earpiece`,
`speaker`, `bluetooth`, `wiredHeadset`.

`CallQualitySample`: `rttMs`, `jitterMs`, `packetLossPercent` (over the interval since
the last sample), `codec`, `mos` (an estimate, 1 to 4.5) and `level`
(`CallQualityLevel.good`, `fair`, `poor`). Show a "poor network" warning when
`levelChanged` and the level is `poor`.

`MediaConstraints`: `echoCancellation`, `noiseSuppression`, `autoGainControl` (all true
by default) and `preferredAudioCodecs` (encoding names to list first, such as
`['opus']`; the media server makes the final choice). `audio` and `video` are deprecated
and ignored: a call always opens the microphone and never the camera.

`IceConfig(servers:, iceTransportPolicy:)`: `IceServerConfig(urls:, username:, credential:)`
entries (default: Google's public STUN server) and `IceTransportPolicy.all` or `.relay`.
`TurnServers.withFallbacks(host:, username:, credential:, port:, tlsHost:, tlsPort:, udp:,
tcp:, tls:)` builds one TURN entry reachable over UDP, TCP and TLS on 443;
`TurnServers.hasRelay(config)` and `hasTls443Fallback(config)` check a config. The SDK
ships no TURN credentials.

### Transfer and recordings (demo only)

```dart
Future<String> transferCall({
  String? number,                 // E.164: a blind <Dial><Number>
  String? sipUser,                // an endpoint: <Dial><User> with sipHeaders
  TransferLeg leg = TransferLeg.aLeg,
  String? callerId,               // a plus and 7 to 15 digits
  Map<String, String> sipHeaders = const {},
})
```

The webhook server makes the transfer with the account Auth ID and Auth Token, so it
needs a Zero-Config sign-in, which needs `unsafeDemoZeroConfig`. Throws `StateError`
unless the call is answered and the client signed in with Zero-Config ("Transfer needs
Zero-Config Setup"), or before Vobiz has reported the call's CallUUID; `ArgumentError`
unless exactly one of `number` and `sipUser` is given and valid, for a caller ID that is
not a plus and 7 to 15 digits, for invalid headers, or when `backendUrl` is not `https`;
and `VobizException` (`transfer_failed`) when the server or Vobiz refuses. Headers whose
names contain characters other than letters and digits cannot travel in XML and are left
out (logged). Returns the server's confirmation.

`leg` names the legs the way Vobiz does, by who started the call: `TransferLeg.aLeg`
moves the side that started the call (you, on a call you placed; the caller, on a call
that rang you) and drops the other side; `bLeg` moves the side the call's `<Dial>`
reached and drops the other; `both` moves both. Transfers go through the Vobiz Redirect
API, never SIP REFER. In production, transfer from your own backend with the Vobiz API
and `client.callUuid`.

| Method | Notes |
|---|---|
| `Future<List<VobizRecording>> fetchRecordings()` | `GET <backendUrl>/api/recording?list=1`, most recent first. **Sends no credentials**: any server that answers it gives its list to whoever knows the address. On the shared demo server it throws `VobizException` (`recordings_failed`) unless `unsafeDemoZeroConfig` is true |
| `Future<VobizRecording?> waitForRecording(String callUuid, {Duration interval = const Duration(milliseconds: 2500), int attempts = 12})` | Polls `fetchRecordings` until the recording for that call arrives, or returns null. On the shared demo server without demo mode it throws `VobizException` (`recordings_failed`) at once, without polling |

Both are for the Playground server. A production app lists recordings through its own
authenticated API.

## Incoming calls to a closed app (Vobiz push)

When a SIP user is called while its app is closed, Vobiz's registrar holds the call for
up to 30 seconds and pushes the phones signed up for that user. The app hands the push
to the client, which claims the held call with its next REGISTER; the call then arrives
as a normal incoming call. Android only for now. The flow and its limits are in
[doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md).

### Reading the push

`static VobizIncomingPush? VobizIncomingPush.tryParse(Map<String, Object?> data)` reads a
push's data map (`RemoteMessage.data` from `firebase_messaging`, for example). Null unless
`type` is `incoming_call`, `call_id` is not empty and `index`, `label` and `registrar` are
all there without control characters.

| Member | Meaning |
|---|---|
| `String callId` | The SIP Call-ID of the INVITE the registrar holds |
| `VobizPushHold hold` | Where the registrar holds the call: `index`, `label`, `registrar`, and `registerHeaders` (`X-Index`, `X-Label`, `X-vobiz-Registrar-Info`), which the claiming REGISTER carries |
| `String caller`, `String callerNumber`, `String callee`, `String callUuid` | Who is calling, the caller's number, the SIP user called, Vobiz's CallUUID |
| `DateTime? expiresAt` | When Vobiz stops holding the call (`expires_at`, Unix seconds; a value too large to be seconds is read as milliseconds) |
| `bool isExpired([DateTime? now])` | `expiresAt` has passed by this phone's clock |
| `bool matchesIncomingCall({required String? sipCallId})` | Whether an incoming call (its `CallEvent.sipCallId`) is this push's call: an exact Call-ID match only, never the caller's number |
| `static DateTime epochToDateTime(int value)` | Unix seconds or milliseconds, told apart by size |

### Handing it to the client

| Member | Notes |
|---|---|
| `bool handleIncomingPush(VobizIncomingPush push)` | Claims the held call. Registered: a REGISTER with the hold reference goes at once. Signed in but between connections, or after reconnecting gave up: the client reconnects at once and that REGISTER carries it. Signed out: sign in now, and the sign-in's REGISTER carries it. Returns false and does nothing for a push whose `expires_at` passed more than 30 s ago by this phone's clock (a phone's clock may run ahead of Vobiz's), or whose hold reference cannot go into a REGISTER; take the call screen down then. A repeat of the push being handled returns true and does nothing more |
| `void reportCallScreenAccepted(VobizIncomingPush push)` | Accept was tapped: answers the call now if it is ringing, or as soon as its INVITE arrives. A push not handed over yet (Accept after a cold start) is handled first |
| `void reportCallScreenDeclined(VobizIncomingPush push)` | Decline was tapped: declines the call now, or as soon as its INVITE arrives. The claim still goes, so the call is declined (486) instead of ringing out the registrar's hold |
| `Stream<VobizPushCallUpdate> pushCallUpdates` | What becomes of each pushed call: `push`, `status`, and `callId` once its INVITE has arrived |
| `VobizIncomingPush? pushedCall` | The push whose call is awaited or ringing |
| `bool isPushedCall(String callId)` | Whether a `CallEvent.callId` is the pushed call |

`VobizPushCallStatus`: `claiming` (the claiming REGISTER is on its way, or waits for the
sign-in), `claimed` (the registrar took it), `ringing` (the INVITE arrived), `answering`
and `declining` (from the call-screen reports), and `expired`: no INVITE came in time, so
take the call screen down. In time means by the push's `expires_at` plus 30 s, and never
more than 60 s after the push was handed over (30 s for a push without `expires_at`).

### Signing the phone up: VobizPushDevices

Vobiz pushes a call only to the devices signed up for the called SIP user. Sign the
phone up after each sign-in and whenever Firebase replaces its token; remove it at
sign-out.

```dart
VobizPushDevices({
  required FutureOr<Map<String, String>> Function() authHeaders, // called for every request
  Uri? baseUrl,                  // default: https://api.vobiz.ai
  String pathPrefix = '/api/v1/devices',
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 15),
})
```

| Member | Notes |
|---|---|
| `Future<void> register(VobizPushDevice device)` | `POST <baseUrl><pathPrefix>/register` with the device as JSON. Throws `ArgumentError` without a device id, push token or SIP username |
| `Future<void> logout(String deviceId)` | `DELETE <baseUrl><pathPrefix>/logout` with `{"device_id": ...}` |
| `void close()` | Closes the HTTP client, unless it was passed in |
| `static Map<String, String> accountHeaders(String authId, String authToken, {required bool unsafeDemo})` | **Demo only.** The account's `X-Auth-ID` and `X-Auth-Token` headers, for signing up straight to Vobiz from a test build. Throws `VobizDemoModeRequiredException` unless `unsafeDemo` is true |

Both requests throw `VobizException` (`push_device_failed`, with `statusCode` when the
server answered) when they are refused, the server cannot be reached, or the whole reply
has not arrived within `timeout`. A path on `baseUrl` is kept in front of `pathPrefix`.

`VobizPushDevice(deviceId:, pushToken:, sipUsername:, appBundleId:, platform: 'android',
pushType: 'voip', appVersion: '', sdkVersion: '')` is sent as `device_id`, `push_token`,
`platform`, `push_type`, `app_bundle_id`, `app_version`, `sdk_version` and
`sip_username`. `deviceId` is a stable id for this install (make one and keep it);
`sipUsername` is `client.sipUsername`; `appBundleId` is the package name the Vobiz
Console's push credential is saved for; pass `VobizClient.sdkVersion` as `sdkVersion`.

**Production: through your backend.** Vobiz's device API takes the account's Auth ID and
Auth Token, which must never ship in an app. Point `baseUrl` at your own backend, which
authenticates your user, adds the account credentials and forwards the request to Vobiz:

```dart
final devices = VobizPushDevices(
  baseUrl: Uri.parse('https://api.example.com'),
  pathPrefix: '/voice/push-devices',
  authHeaders: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
);
```

Your backend must follow two rules, because Vobiz scopes devices to the account, not to
the SIP user:

1. Take `sip_username` from the signed-in user (their endpoint, or `<sub>_<auth_id>` for
   an access token), never from the request.
2. Remove only devices that this user registered.

[CREDENTIALS.md](CREDENTIALS.md#push-sign-up-through-your-backend) has a reference
backend. The example's sample server implements the same routes as
`/push/devices/register` and `/push/devices/logout`
([example/push_bridge/README.md](example/push_bridge/README.md#vobiz-push-sign-up)).

## VobizConference

Turns the client's current call into a Vobiz conference room and manages the people in
it, through your server, which holds the Auth Token.

```dart
VobizConference({
  required VobizClient client,
  required Uri serverUrl,                              // your server's base URL
  FutureOr<Map<String, String>> Function()? headers,   // e.g. your Authorization
  String? Function()? callUuid,                        // default: client.callUuid
  http.Client? httpClient,
  Duration pollInterval = const Duration(seconds: 2),
  Duration timeout = const Duration(seconds: 15),
  bool endCallWithConference = true,                   // hang up when the room ends
})
```

`callUuid` is the id your server knows the current call by; the default is Vobiz's
CallUUID for this app's own leg. When the conference ends (the server reports
`active: false`, or `end()` returns), the client's call is hung up too unless
`endCallWithConference` is false: the call's leg was in the room, and Vobiz's own hang-up
does not always reach the phone.

| Member | Notes |
|---|---|
| `ValueListenable<VobizConferenceState?> state` | The current call's conference; refreshed every `pollInterval` while it is on, null when the call is not one or has ended |
| `Future<VobizConferenceState> add({String? number, String? sipUser, String? callerId})` | Dials one person in: a `number` (a plus and 7 to 15 digits) or a `sipUser` (letters, digits and `_ . - +`, at most 120). `callerId` (same number rule) is what they see; without it your server picks one. The first add makes the call a conference: both of its sides move into a new room. Needs an answered call |
| `mute(id)`, `unmute(id)`, `hold(id)`, `resume(id)`, `remove(id)` | One participant, by `VobizConferenceParticipant.id`. Hold takes them out of the room onto music |
| `act(id, VobizParticipantAction action)` | The same, by value |
| `Future<VobizConferenceState> end()` | Ends it for everyone, this call included |
| `Future<VobizConferenceState?> refresh()` | Asks the server now; null when the call is not a conference. A conference another `VobizConference` started for the same call is taken over |
| `void dispose()` | Stops listening; closes the HTTP client if it made it |

Refusals throw `VobizException` (`conference_failed`, with `statusCode`); malformed input
throws `ArgumentError`; no answered call, no CallUUID yet, or a control used when the call
is not a conference throws `StateError`. A reply that arrives after its call ended does
not act on the next call.

`VobizConferenceState`: `room`, `active`, `participants`, `endedReason`, and `present`
(the people still in it). `VobizConferenceParticipant`: `id`, `label`, `status`
(`VobizParticipantStatus.connecting`, `dialing`, `joined`, `onHold`, `left`, `failed`),
`isYou`, `role` (`host`, `guest`, `added`, `other`), `muted`, `reason`, `isPresent`.

Server routes (JSON bodies; each answers with the state as JSON:
`{room, active, ended_reason?, participants: [{id, label, you, role, status, muted, reason?}]}`,
`status` one of `connecting`, `dialing`, `joined`, `on_hold`, `left`, `failed`):

| Route | Body |
|---|---|
| `POST /conference/add` | `call_uuid`, `number` or `user`, optional `caller_id` |
| `POST /conference/state` | `call_uuid` (404 when the call is not a conference) |
| `POST /conference/participant` | `call_uuid`, `participant_id`, `action` (`mute`, `unmute`, `hold`, `resume`, `remove`) |
| `POST /conference/end` | `call_uuid` |

An error answers `{error, conference?}`.

## Events

| Stream on `VobizClient` | Event |
|---|---|
| `connectionEvents` | `ConnectionEvent`: `connectionState`, `registrationState`, `message` |
| `callEvents` | `CallEvent` (below) |
| `callMediaEvents` | `CallMediaEvent`: see [Audio and media](#audio-and-media) |
| `mediaEvents` | `MediaEvent`: `callId`, `localStream`, `remoteStream`, `message` |
| `networkEvents` | `NetworkEvent`: see [Network and reconnection](#network-and-reconnection) |
| `errorEvents` | `ErrorEvent`: `code` (a [`VobizErrorCode`](#error-codes)), `message`, `cause` |
| `pushCallUpdates` | `VobizPushCallUpdate`: see [Vobiz push](#handing-it-to-the-client) |

All of them except `VobizPushCallUpdate` extend `SdkEvent`, which has a `timestamp`.

`CallEvent`: `callId`, `state`, `message`, `direction`, `remoteIdentity`, `callUuid`,
`headers`, `sipCallId` (the call's SIP Call-ID), and on failure `sipCode` and `reason`
(with the Q.850 cause when the far end gave one, such as
`Remote party is busy — USER_BUSY (Q.850 17)`). A failed call emits `failed` and then
`ended`. During a call, `reason` is `reconnecting` while the call rides out a network
loss and `reconnected` when it is back; an ended call's `reason` can be `network_lost`,
`ended_while_offline`, `setup_timeout`, `answer_failed` or `disconnected` (signed out).

## Network and reconnection

`networkEvents` reports the device's network and the signalling connection.
`NetworkEvent`: `type`, `network` (`NetworkStatus`: `types`, `isOnline`, `primary`), and
`previousNetwork`, `quality` (`SignalingQuality.good`, `degraded`, `unavailable`),
`attempt`, `retryIn` and `reason`. `NetworkEventType`: `offline`, `online`,
`networkChanged`, `reconnecting`, `reconnected`, `reconnectFailed`.

- **Reconnecting.** When the connection drops, the client reconnects with the backoff of
  `SdkConfig.reconnectPolicy`: 1 s, doubling to 30 s, each delay spread by ±20 %. While
  the device has no network it makes no attempts and counts none, and it reconnects at
  once when the network comes back or changes. After 10 failed attempts it stops:
  `ConnectionStateStatus.failed`, an `ErrorEvent` `reconnect_failed`, and a
  `reconnectFailed` network event. A network change or `reconnect()` starts again.
- **Registrar answers.** With `autoReconnect`, a REGISTER the registrar could not take
  for now (no answer, 408, 480 or 5xx) is retried with the same backoff and the state
  stays `reconnecting`. A refusal (401, 403, 404, 407, a refused access token, or any
  other final answer) ends the sign-in with `registration_failed`. A temporary failure
  during a call is retried once the call has ended; the call keeps its connection
  meanwhile.
- **Keep-alive.** A WebSocket ping every 15 s (`SdkConfig.keepAlive`); a socket that
  does not answer is closed within 30 s and reconnected.
- **Cleartext.** A release build refuses a `ws:` registrar URL to anything but this
  device (`ArgumentError`): the REGISTER carries the password or the access token.

`ReconnectPolicy(initialDelay: 1 s, maxDelay: 30 s, multiplier: 2.0, maxAttempts: 10,
jitter: 0.2)`; `maxAttempts: null` retries forever. `KeepAliveConfig(pingInterval: 15 s,
crlfInterval: null, crlfPongTimeout: 10 s)`. `SdkConfig.watchNetwork` (default true)
watches the device's network through `PlatformConnectivityMonitor`; without it a lost
network is noticed only by the keep-alive. `ConnectivityMonitor` (`current()`,
`changes`) and `AppLifecycleMonitor` (`foregroundChanges`; `NoAppLifecycleMonitor` never
reports) can be supplied to the `VobizClient` constructor.

### Returning to the foreground

The SDK re-registers by itself each time the app comes back to the foreground
(`AppLifecycleState.resumed` after `hidden`, `paused` or `detached`), so Vobiz has the
device's current IP address after it was locked or in the background. No app code is
needed.

- Registered on a live socket: one REGISTER on that socket; the refresh timer restarts
  from the new grant. A call in progress keeps its socket and dialog. After a phone is
  locked the socket is often dead without having been closed: if the registrar does not
  answer within 5 s the socket is dropped and the client reconnects at once, keeping a
  call's dialog. The periodic refresh does the same after its 32 s timeout. A refusal
  (403, say) still fails the registration.
- Socket dropped, reconnecting or given up: reconnects now with the backoff reset
  (a `NetworkEvent` `reconnecting` with reason `App returned to the foreground`, then
  `reconnected`).
- Signed out, or a resume within 2 s of the last one: nothing.

The refresh reports a `ConnectionEvent` with message `Reregistered on foreground` and
logs `reregistered on foreground`. Turn it off with
`SdkConfig(reregisterOnForeground: false)`.

### When the network drops during a call

A connected (or held) call survives a short loss of network, audio included:

- When the SIP connection or the call's media drops, the call gets a `CallEvent` with
  `reason: 'reconnecting'` (its state does not change) and a fixed grace period of 12 s
  to come back. A call still being set up, or still ringing, ends at once with
  `network_lost` (a ringing incoming call is declined with 486).
- When the network returns after a complete outage (airplane mode, or Wi-Fi and mobile
  data both off), the client opens a new connection at once. It does not wait for the
  old one to report that it died: Android can leave a dead socket looking open until a
  keep-alive ping times out, which takes longer than the grace period.
- Once the client has registered again on a new connection, it restarts ICE: new ICE
  credentials and candidates gathered on the network the device has now, offered in an
  in-dialog re-INVITE on that connection, so the far end's later requests (its BYE, say)
  reach the new connection. The grace period starts again with the restart.
- When only the audio drops while the SIP connection stays up (ICE reports `failed`, or
  `disconnected` for 3 s), the client restarts ICE once for that loss in the same way.
- When ICE connects the call gets `reason: 'reconnected'`. If it is not back in time the
  call ends with reason `network_lost` and an `ErrorEvent` `network_lost`.
- If Vobiz answers the restart's re-INVITE with 481, the call ended on Vobiz while the
  phone was offline: the far end hung up, or the call was transferred away. The call
  ends at once with reason `ended_while_offline`, without a BYE and without an
  `ErrorEvent`.

A call that ends while the device is offline (its grace period ran out, or the user hung
up) cannot tell Vobiz at that moment: its BYE, or the CANCEL of a call still ringing,
never leaves the phone. The client keeps it and sends it again as soon as it has
registered on a new connection. It is sent again at most 3 times, within 5 minutes, and
only while the same user is signed in; any final response ends it, a 481 (the call was
already over) included. Two cases this cannot cover:

- **The device stays offline.** Vobiz keeps the other party connected, and billed, until
  its media servers time the call out (about 5 minutes). The example's sample server
  shows one way to end such calls from a server
  ([example/push_bridge/README.md](example/push_bridge/README.md#connection-watch)).
- **The other party answered during the outage.** A CANCEL cannot end an answered call,
  and the client never saw the answer, so it has no dialog to send a BYE in. Vobiz ends
  the call by itself when its answer is never acknowledged (SIP allows 32 s for the ACK).

## Errors

| Type | Code | Thrown when |
|---|---|---|
| `VobizException` | any | Base class: `code`, `message`, `statusCode`, `cause` |
| `VobizDemoModeRequiredException` | `demo_mode_required` | `connectWithAuthToken` without `SdkConfig.unsafeDemoZeroConfig`, or `VobizPushDevices.accountHeaders` without `unsafeDemo: true` |
| `VobizCredentialsException` | `credentials_failed` | Your credentials provider (or backend) failed or returned an empty username or password |
| `VobizRegistrationException` | `registration_failed` | The registrar kept refusing fresh credentials (on `VobizCredentialsSession.failures`) |
| `VobizAccessTokenException` | `access_token_failed` | An access token could not be decoded or presented, your token provider failed, the token does not allow an outgoing call, or (on `VobizAccessTokenSession.failures`) the registrar kept refusing fresh tokens. `tokenError` / `tokenErrorName` carry the reason (10001 to 10010); it is also the `cause` of a `registration_failed` event when a token is refused |

Methods also throw `StateError` (wrong call or sign-in state) and `ArgumentError`
(invalid input) as documented above. `transferCall` without Zero-Config throws
`StateError`, not `VobizDemoModeRequiredException`.

### Error codes

The constants on `VobizErrorCode`, as `VobizException.code` and `ErrorEvent.code`:

| Constant | Value | When |
|---|---|---|
| `setupFailed` | `setup_failed` | Zero-Config Setup failed or the webhook server refused it |
| `transferFailed` | `transfer_failed` | A transfer through the webhook server failed |
| `recordingsFailed` | `recordings_failed` | The recordings list could not be read, or was refused (the shared demo server outside demo mode) |
| `demoModeRequired` | `demo_mode_required` | See `VobizDemoModeRequiredException` |
| `credentialsFailed` | `credentials_failed` | See `VobizCredentialsException` |
| `connectFailed` | `connect_failed` | The WebSocket to the registrar could not be opened at sign-in |
| `registrationFailed` | `registration_failed` | The registrar refused the sign-in. Not reported for a temporary failure that is being retried |
| `reconnectFailed` | `reconnect_failed` | Reconnecting gave up after the policy's last attempt |
| `networkLost` | `network_lost` | A call ended because its network did not come back within the grace period |
| `holdFailed`, `resumeFailed` | `hold_failed`, `resume_failed` | The far end refused the hold or resume re-INVITE |
| `socketError` | `socket_error` | The WebSocket dropped |
| `makeCallFailed` | `make_call_failed` | An outbound call could not be started |
| `answerFailed` | `answer_failed` | An incoming call could not be answered |
| `callFailed` | `call_failed` | A call failed |
| `callTimeout` | `call_timeout` | An outbound INVITE got no response at all within 30 s |
| `authFailed` | `auth_failed` | A call's credentials were refused (401/407 after the digest answer) |
| `accessTokenFailed` | `access_token_failed` | See `VobizAccessTokenException` |
| `conferenceFailed` | `conference_failed` | A conference request failed or was refused |
| `pushDeviceFailed` | `push_device_failed` | Signing the phone up for Vobiz push, or removing it, failed |

## SdkConfig

| Field | Default | |
|---|---|---|
| `wsUrl` | `wss://registrar.vobiz.ai:5063/` | SIP over WebSocket. A release build refuses `ws:` except to this device |
| `sipServer` | `registrar.vobiz.ai` | SIP domain |
| `backendUrl` | `SdkConfig.defaultWebhookUrl` = `https://rtc-demo.vobiz.ai` | The webhook server: Zero-Config Setup, transfers and the recordings list. The default is the shared demo server, used only in demo mode |
| `voiceApiUrl` | `SdkConfig.defaultVoiceApiUrl` = `https://api.vobiz.ai` | The Vobiz API the webhook server calls for you |
| `autoReconnect` | `true` | Reconnect when the connection drops; see [Network and reconnection](#network-and-reconnection) |
| `reconnectPolicy` | `ReconnectPolicy()` | 1 s doubling to 30 s, ±20 %, giving up after 10 attempts with `reconnect_failed` |
| `keepAlive` | `KeepAliveConfig()` | A WebSocket ping every 15 s |
| `watchNetwork` | `true` | React to the device's network at once: fail calls fast while offline, reconnect as soon as it is back or changes |
| `reregisterOnForeground` | `true` | Re-register (or reconnect) each time the app returns to the foreground; see [Returning to the foreground](#returning-to-the-foreground) |
| `debug` | `false` | SDK logs to the console |
| `iceConfig` | Google STUN | Add TURN for restrictive networks |
| `mediaConstraints` | echo cancellation, noise suppression, AGC | See [Audio and media](#audio-and-media) |
| `unsafeDemoZeroConfig` | `false` | **Demo only.** Allows `connectWithAuthToken` (and so `transferCall`) and the demo server's recordings list, which send or expose account credentials. Never ship with it set |

## VobizSipHeaders

The custom-header rules, identical to the Vobiz web SDK's:

- Names: `X-VH-` plus 1-19 letters, digits or hyphens; or `X-Vobiz-JWT`.
- Values: `A-Z a-z 0-9 _ - + ( ) % .`, no spaces, up to 120 characters (500 for the JWT).

| Member | |
|---|---|
| `prefix`, `jwt`, `record`, `dialUser`, `callerId` | Header names |
| `bool isJwt(String name)` | Whether a name is the JWT header |
| `String? validateName(String)`, `String? validateValue(String name, String value)` | A reason, or null when valid |
| `HeaderCheck check(Map<String, String>)` | `valid` headers and one `errors` line per rejected one (duplicates are case-insensitive) |
| `Map<String, String> pick(Map<String, String>)` | Only the valid custom headers, as an incoming call reports them |
| `XmlSipHeaders toXml(Map<String, String>)` | The `sipHeaders` attribute value (`OrderId=A1234,…`) and the headers that cannot be expressed in it |

## Models

| Type | Fields |
|---|---|
| `CredentialConfig` | `username`, `password`, `displayName` (for the app's own use; the SDK does not send it) |
| `TokenConfig` (deprecated) | `token` (sent as the SIP password), `displayName` (used as the SIP username). Not a JWT: for one use `connectWithAccessToken` |
| `VobizAccessToken` | `VobizAccessToken.parse(token)`; `token`, `sipUsername`, `accountId`, `subject`, `appId`, `notBefore`, `expiresAt`, `incomingAllowed`, `outgoingAllowed`, `canCallOut`, `canReceiveCalls`, `isExpired()`, `timeLeft()`. The SDK never checks the signature (the registrar does), and `toString()` never prints the token |
| `ZeroConfigSession` | `sipUsername`, `sipPassword`, `applicationId`, `message`, `reusedExisting` |
| `CallSession` | `client.currentCall`: `callId`, `remoteIdentity`, `isIncoming`, `state`, `callUuid`, `headers`, `muted`, `speakerEnabled`, `actions` (`CallActions`: `canAnswer`, `canReject`, `canHangup`, `canMute`, `canHold`, `canResume`, `canSendDtmf`). A snapshot: changing it does not change the call |
| `CallStats` | `rttMs`, `jitterMs`, `packetLossPercent` |
| `VobizRecording` | `recordingId`, `callUuid`, `url`, `durationSecs`, `endReason`, `receivedAt` |
| `VobizPushDevice`, `VobizIncomingPush`, `VobizPushHold`, `VobizPushCallUpdate` | See [Vobiz push](#incoming-calls-to-a-closed-app-vobiz-push) |
| `Logger` | `Logger({LogWriter? writer})`: pass to `VobizClient(logger:)` to receive SDK log lines. `SdkConfig(debug: true)` prints them instead |

## Enums

| Enum | Values |
|---|---|
| `VobizAuthMode` | `none`, `zeroConfig`, `sipDirect` (also after `connectWithCredentialsProvider`), `accessToken` (`connectWithAccessToken` and `connectWithAccessTokenProvider`) |
| `VobizCredentialsRequest` | `signIn`, `rejected`, `refresh` |
| `VobizAccessTokenRequest` | `signIn`, `expiring`, `rejected`, `refresh` |
| `CallStateStatus` | `idle`, `incoming`, `ringing`, `connecting`, `active`, `held`, `ended`, `failed` |
| `CallDirection` | `inbound`, `outbound` |
| `TransferLeg` | `aLeg` (`aleg`: the side that started the call), `bLeg` (`bleg`: the side its `<Dial>` reached), `both` |
| `DtmfTransport` | `auto`, `rfc4733`, `sipInfo` |
| `ConnectionStateStatus` | `disconnected`, `connecting`, `connected`, `reconnecting`, `failed` |
| `RegistrationState` | `unregistered`, `registering`, `registered`, `failed` |
| `NetworkEventType` | `offline`, `online`, `networkChanged`, `reconnecting`, `reconnected`, `reconnectFailed` |
| `SignalingQuality` | `good`, `degraded`, `unavailable` |
| `NetworkType` | `none`, `wifi`, `mobile`, `ethernet`, `vpn`, `other` |
| `AudioRoute` | `earpiece`, `speaker`, `bluetooth`, `wiredHeadset` |
| `CallQualityLevel` | `good`, `fair`, `poor` |
| `IceTransportPolicy` | `all`, `relay` |
| `VobizPushCallStatus` | `claiming`, `claimed`, `ringing`, `answering`, `declining`, `expired` |
| `VobizParticipantStatus` | `connecting`, `dialing`, `joined`, `onHold`, `left`, `failed` |
| `VobizParticipantAction` | `mute`, `unmute`, `hold`, `resume`, `remove` |
