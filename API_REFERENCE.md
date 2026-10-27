# Vobiz WebRTC SDK for Flutter: API reference

Everything below is exported by `package:vobiz_webrtc/vobiz_webrtc.dart`.

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
| `Future<VobizAccessTokenSession> connectWithAccessTokenProvider(VobizAccessTokenProvider provider, {Duration refreshBefore = const Duration(seconds: 60), int maxRefreshes = 1})` | **Production**, access token | Asks your provider for an access token (JWT), registers with it, fetches the next one `refreshBefore` ahead of each token's expiry and registers again without touching a call, and asks again when the registrar refuses one. The web SDK's `loginWithAccessTokenGenerator`. Throws `VobizAccessTokenException` when the provider fails |
| `Future<void> connectWithAccessToken(String accessToken)` | Access token | Registers as `<sub>_<iss>` with the token instead of a password. Not renewed (use the provider, or `updateAccessToken`). The web SDK's `loginWithAccessToken`. Throws `VobizAccessTokenException` (10001) for a token it cannot decode |
| `Future<void> updateAccessToken(String accessToken)` | Access token | Registers again now with a fresh token for the same user, on the open socket; also recovers a refused sign-in. Throws `StateError` unless signed in with a token, `ArgumentError` for another user's token |
| `Future<void> connectWithCredentials(CredentialConfig config)` | SIP Direct | Registers as an existing endpoint |
| `Future<ZeroConfigSession> connectWithAuthToken({required String authId, required String authToken})` | Zero-Config Setup, **demo only** | Throws `VobizDemoModeRequiredException` unless `SdkConfig.unsafeDemoZeroConfig` is true. Then posts the Auth ID and Auth Token to `<backendUrl>/api/setup` and registers as the returned endpoint (whose password it rotates). Throws `VobizException` (`setup_failed`) when refused, `ArgumentError` when either value is blank |
| `Future<void> connect(Object credentials)` | SIP Direct | Accepts `CredentialConfig`, or the deprecated `TokenConfig` (its token is sent as the SIP password; it is not token auth) |
| `Future<void> disconnect()` | | Unregisters, ends any call, and drops the Auth ID and Auth Token |
| `Future<void> dispose()` | | `disconnect()` and closes the streams |

`connectWithCredentialsProvider` is an extension method
(`VobizClientCredentialsProvider`). The provider is
`Future<CredentialConfig> Function(VobizCredentialsRequest request)`, asked with
`signIn`, `rejected` (after a 401/403) or `refresh` (`session.refresh()`).
`VobizCredentialsSession` has `failures` (a stream of `VobizException`), `refresh()` and
`dispose()`. `VobizBackendCredentialsProvider(url:, headers:)` is a ready-made provider
that POSTs `{"reason": ...}` to your backend and reads
`{"sip_username", "sip_password", "display_name"?}`; pass `provider.call`.

A new sign-in replaces the previous connection. Registration finishes asynchronously:
watch `connectionEvents` for `RegistrationState.registered` or `.failed`.

| Getter | Meaning |
|---|---|
| `VobizAuthMode authMode` | `none`, `zeroConfig`, `sipDirect` or `accessToken` |
| `String? sipUsername` | The SIP user this client registers as: the endpoint, or `<sub>_<iss>` for an access token |
| `VobizAccessToken? accessToken` | The access token signed in with: `sipUsername`, `accountId` (`iss`), `subject` (`sub`), `appId` (`app`), `notBefore`, `expiresAt`, `canCallOut`, `canReceiveCalls`. Null for other sign-ins |
| `Duration? accessTokenTimeLeft` | How long the registrar said the token had left at the last REGISTER (its clock, not the device's) |
| `bool isConnected` | Socket connected and registered |
| `RegistrationState registrationState`, `ConnectionStateStatus connectionState` | |
| `String backendUrl` | The webhook server. Mutable: set it before signing in to use another one |

### Access tokens (JWT)

Your backend mints the token with `POST /api/v1/Account/{auth_id}/JWT/Token/` (account
Auth ID and Auth Token, which stay on the server) and claims
`{"iss": "<auth_id>", "sub": "<your user id>", "nbf": <s>, "exp": <s>, "app": "<application id>",
"per": {"voice": {"incoming_allow": true, "outgoing_allow": true}}}`. See
[CREDENTIALS.md](CREDENTIALS.md#access-tokens-jwt).

- **Identity.** The client registers as `<sub>_<iss>`: no endpoint has to exist in the
  Console. To ring the user, dial `<User>sip:<sub>_<iss>@registrar.vobiz.ai</User>`.
- **On the wire.** Every REGISTER and every outbound INVITE carries `X-Vobiz-Jwt: <token>`
  instead of answering a digest challenge. The registrar validates it and tags the INVITE
  with the account and the token's `app`, whose Answer URL then handles the call (the
  account's default application without `app`). The SDK never logs the token.
- **Grants.** `makeCall` throws `VobizAccessTokenException` (10008
  `INVALID_ACCESS_TOKEN_GRANTS`) unless `per.voice.outgoing_allow` is true, before
  anything is sent. The SDK does not check `incoming_allow`; the platform does.
- **Expiry.** The registrar caps the registration at the token's remaining life and
  reports it (`X-vobiz-Jwt: expires=<s>;epoch-exp=<t>`, see `accessTokenTimeLeft`). The
  provider session asks for the next token `refreshBefore` (60 s) ahead of `exp`, never
  sooner than 5 s from now, and registers with it on the same socket. With
  `connectWithAccessToken` alone, call `updateAccessToken` yourself.
- **Refusals.** A refused REGISTER fails the registration: an `ErrorEvent` with code
  `registration_failed` whose `cause` is a `VobizAccessTokenException` carrying the
  registrar's `X-vobiz-Jwt-Error-Code`. A refused INVITE fails the call with the same
  name in its reason. The provider session then asks for a new token (`rejected`),
  except for 10005 `ACCESS_TOKEN_NOT_VALID_YET`, where it presents the same token again
  3 s later: the registrar's clock was behind the minting server's.
- **Minting tips** (seen live): include `app` (without it the registrar can refuse the
  token with 10001), and set `nbf` a minute in the past (else 10005 while the
  registrar's clock is behind). `sub` is letters, digits, `_` or `-`, at most 50.

| `tokenError` | `tokenErrorName` (as the web SDK's `getErrorStringByErrorCodes`) | Meaning |
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
`VobizAccessTokenSession` has `nextRefreshAt`, `failures`, `refresh()` and `dispose()`.
`VobizBackendAccessTokenProvider(url:, headers:)` POSTs `{"reason": ...}` to your backend
and reads `{"token": ...}` (the Vobiz WebRTC demo's `/token` answers that way); pass
`provider.call`.

### Calls

```dart
Future<String> makeCall(
  String destination, {        // E.164, such as +919876543210
  String? callerId,            // sent as X-VH-Caller-ID
  Map<String, String> headers = const {},  // custom X-VH- headers
  bool record = false,         // X-VH-Record: true
  String? dialUser,            // X-VH-DialUser: ring this endpoint instead
})
```

Returns the client's call ID. Throws `StateError` when not registered or already in a
call, and `ArgumentError` naming every invalid header or caller ID before anything is
dialled.

| Method | Notes |
|---|---|
| `Future<void> acceptCall([String? callId])` | Answers the ringing incoming call |
| `Future<void> rejectCall([String? callId])` | Declines it (486 Busy Here) |
| `Future<void> hangup([String? callId])` | Ends the call |
| `Future<void> mute([String? callId])`, `unmute(...)` | Microphone |
| `Future<void> setSpeakerphone(bool enabled)` | Loudspeaker or earpiece |
| `Future<void> sendDtmf(String digits, {DtmfTransport transport = DtmfTransport.auto})` | `0-9 * # A-D`. `auto`: RFC 4733 telephone-events in the audio when the call negotiated `telephone-event`, otherwise `application/dtmf-relay` SIP INFO, 500 ms apart. `StateError` without a connected call |
| `Future<void> hold([String? callId])`, `resume(...)` | A re-INVITE with `a=sendonly` (hold) or `a=sendrecv` (resume). State `held` / `active`, `HoldChangedEvent`. Throws `VobizException` (`hold_failed` / `resume_failed`) when refused; the call carries on as it was |
| `Future<void> audioInterruptionBegan()`, `audioInterruptionEnded({bool shouldResume = true})` | Another app's call took the microphone: holds the connected call, and resumes it after |
| `Future<CallStats?> getCallStats()` | `rttMs`, `jitterMs`, `packetLossPercent` from WebRTC stats; a field is null until measured |
| `static Map<String, String> buildCallHeaders({...})` | What `makeCall` would send for these options, validated. For checking a form |
| `static String endpointUsername(String? value)` | `sip:play1@registrar.vobiz.ai` → `play1` |

| Getter | Meaning |
|---|---|
| `CallStateStatus callState` | `idle` between calls |
| `CallDirection? callDirection` | `inbound` or `outbound` |
| `String? callUuid` | Vobiz's CallUUID for this leg (the `X-Calluuid` header), once reported |
| `String? lastCallUuid` | The CallUUID of the most recent ended call |
| `Map<String, String> callHeaders` | Custom headers sent (outbound) or received (inbound) |
| `bool isMuted` | |

### Transfer and recordings

```dart
Future<String> transferCall({
  String? number,                 // E.164: a blind <Dial><Number>
  String? sipUser,                // an endpoint: <Dial><User> with sipHeaders
  TransferLeg leg = TransferLeg.aLeg,
  String? callerId,
  Map<String, String> sipHeaders = const {},
})
```

Demo only (Zero-Config, which needs `unsafeDemoZeroConfig`), and only on an answered call. Give exactly one of `number` and
`sipUser`. Headers whose names contain characters other than letters and digits cannot
travel in XML and are left out (logged). Returns the server's confirmation; throws
`VobizException` (`transfer_failed`) when the server or Vobiz refuses.

| Method | Notes |
|---|---|
| `Future<List<VobizRecording>> fetchRecordings()` | Everything the webhook server has received, most recent first. Refused for the shared demo server unless `unsafeDemoZeroConfig` is true (its list is not scoped to an account) |
| `Future<VobizRecording?> waitForRecording(String callUuid, {Duration interval, int attempts})` | Polls until the recording for that call arrives (default every 2.5 s, 12 times), or returns null |

### Legacy call control

`transfer(String to)`, `warmTransferStart`, `warmTransferComplete`, `addCall`,
`startSecondCall`, `swapCalls`, `mergeCalls`, `endSecondCall` and `removeAddedCall`
call routes such as `/add-call` on `backendUrl`. Only the Node reference server
implements them. (`hold` and `resume` are SIP re-INVITEs now; see Calls.) For a
conference, use `VobizConference` below.

## VobizConference

Turns the client's current call into a Vobiz conference room and manages the people in
it, through your server (which holds the Auth Token).

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

When the conference ends (the server reports `active: false`, or `end()` returns), the
client's call is hung up too unless `endCallWithConference` is false: the call's leg was in
the room, and Vobiz's own hang-up does not always reach the phone.

| Member | Notes |
|---|---|
| `ValueListenable<VobizConferenceState?> state` | The current call's conference; refreshed every `pollInterval` while it is on, null when the call is not one or has ended |
| `Future<VobizConferenceState> add({String? number, String? sipUser, String? callerId})` | Dials one person in (E.164 `number` or a SIP username). The first call makes the call a conference: both of its sides move into a new room. Needs an answered call |
| `mute(id)`, `unmute(id)`, `hold(id)`, `resume(id)`, `remove(id)` | One participant, by `VobizConferenceParticipant.id`. Hold takes them out of the room onto music |
| `act(id, VobizParticipantAction action)` | The same, by value |
| `Future<VobizConferenceState> end()` | Ends it for everyone, this call included |
| `Future<VobizConferenceState?> refresh()` | Asks the server now; null when the call is not a conference |
| `void dispose()` | Stops listening; closes the HTTP client if it made it |

Refusals throw `VobizException` (`conference_failed`, with `statusCode`); malformed input
throws `ArgumentError`, no answered call or no CallUUID `StateError`.

`VobizConferenceState`: `room`, `active`, `participants`, `endedReason`, and `present`
(the people still in it). `VobizConferenceParticipant`: `id`, `label`, `status`
(`VobizParticipantStatus.connecting`, `dialing`, `joined`, `onHold`, `left`, `failed`),
`isYou`, `role` (`host`, `guest`, `added`, `other`), `muted`, `reason`, `isPresent`.

Server routes (JSON bodies; each answers with the state as JSON:
`{room, active, ended_reason?, participants: [{id, label, you, role, status, muted, reason?}]}`):

| Route | Body |
|---|---|
| `POST /conference/add` | `call_uuid`, `number` or `user`, optional `caller_id` |
| `POST /conference/state` | `call_uuid` (404 when the call is not a conference) |
| `POST /conference/participant` | `call_uuid`, `participant_id`, `action` (`mute`, `unmute`, `hold`, `resume`, `remove`) |
| `POST /conference/end` | `call_uuid` |

An error answers `{error, conference?}`.

### Events

| Stream | Event |
|---|---|
| `connectionEvents` | `ConnectionEvent`: `connectionState`, `registrationState`, `message` |
| `callEvents` | `CallEvent` (below) |
| `mediaEvents` | `MediaEvent`: local and remote streams |
| `errorEvents` | `ErrorEvent`: `code`, `message`, `cause` |

`CallEvent` fields: `callId`, `state`, `message`, `direction`, `remoteIdentity`,
`callUuid`, `headers`, and on failure `sipCode` and `reason` (with the Q.850 cause when
the far end gave one, such as `Remote party is busy — USER_BUSY (Q.850 17)`). A failed
call emits `failed` and then `ended`.

Error codes are constants on `VobizErrorCode`: `setupFailed`, `registrationFailed`,
`socketError`, `connectFailed`, `callFailed`, `callTimeout`, `answerFailed`,
`makeCallFailed`, `transferFailed`, `recordingsFailed`, `demoModeRequired`,
`credentialsFailed`, `authFailed`, `accessTokenFailed`.

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
  `reason: 'reconnecting'` (its state does not change) and up to `networkLossGrace`
  (a `VobizClient` constructor argument, 12 s) to come back. A call still being set up
  ends at once with `network_lost`.
- When the network returns after a complete outage (airplane mode, or Wi-Fi and mobile
  data both off), the client opens a new connection at once. It does not wait for the
  old one to report that it died: Android can leave a dead socket looking open until a
  keep-alive ping times out, which takes longer than the grace period.
- Once the client has registered again on a new connection, it restarts ICE: new ICE
  credentials and candidates gathered on the network the device has now, offered to
  Vobiz in an in-dialog re-INVITE on that connection. Vobiz then sends the call's later
  requests (the far end's BYE, say) to the new connection. The grace period starts
  again with the restart, so gathering, the re-INVITE and the ICE checks get the full
  12 s.
- When ICE connects the call gets `reason: 'reconnected'`. If it is not back in time
  the call ends with reason `network_lost` and an `ErrorEvent` `network_lost`.
- Measured on Android against Vobiz: the audio is back about 1.4 s after the network
  returns (about 1 s after a complete outage), and a switch between Wi-Fi and mobile
  data leaves a gap of about 2 s.

A call that ends while the device is offline (its grace period ran out, or the user hung
up) cannot tell Vobiz at that moment: its BYE, or the CANCEL of a call still ringing,
never leaves the phone. The client keeps it and sends it again as soon as it has
registered on a new connection, so the other party is hung up, or stops ringing, about
a second after the network returns. It is sent again at most 3 times, within 5 minutes,
and only while the same user is signed in; any final response ends it, a 481 (the call
was already over) included. Two cases this cannot cover:

- **The device stays offline.** Vobiz keeps the other party connected, and billed, until
  its media servers time the call out (300 s in our tests). The example's push bridge
  shows one way to end such calls from a server (example/push_bridge/README.md,
  "Connection watch").
- **The other party answered during the outage.** A CANCEL cannot end an answered call,
  and the client never saw the answer, so it has no dialog to send a BYE in. Vobiz ends
  the call by itself when its answer is never acknowledged (SIP allows 32 s for the ACK).

## Errors

| Type | Code | Thrown when |
|---|---|---|
| `VobizException` | any | Base class: `code`, `message`, `statusCode`, `cause` |
| `VobizDemoModeRequiredException` | `demo_mode_required` | An Auth-Token operation without `unsafeDemoZeroConfig` |
| `VobizCredentialsException` | `credentials_failed` | Your credentials provider (or backend) failed |
| `VobizRegistrationException` | `registration_failed` | The registrar kept refusing fresh credentials (on `VobizCredentialsSession.failures`) |
| `VobizAccessTokenException` | `access_token_failed` | An access token could not be decoded, your token provider failed, the token does not allow an outgoing call, or (on `VobizAccessTokenSession.failures`) the registrar kept refusing fresh tokens. `tokenError` / `tokenErrorName` carry the registrar's reason (10001 to 10010); it is also the `cause` of a `registration_failed` event when a token is refused |

Some methods still throw `StateError` (wrong call state) or `ArgumentError` (invalid
input) as documented above.

## Push

`VobizIncomingPush.tryParse(Map<String, Object?> data, {receivedAt})` reads an
incoming-call push (`kind`, `callId`, `caller`, `callee`, `expiresAt`, `lineBusy`,
`isExpired()`). Expiry comes from the sender's relative `ttl_ms`, counted from
arrival. `matchesIncomingCall(headers:)` ties the INVITE that follows to it by an
exact `PushRef` match only, never by phone number. See
[doc/PUSH_DESIGN.md](doc/PUSH_DESIGN.md).

## SdkConfig

| Field | Default | |
|---|---|---|
| `wsUrl` | `wss://registrar.vobiz.ai:5063/` | SIP over WebSocket |
| `sipServer` | `registrar.vobiz.ai` | SIP domain |
| `backendUrl` | `SdkConfig.defaultWebhookUrl` = `https://rtc-demo.vobiz.ai` | The webhook server: Zero-Config Setup, transfers, recordings, and the answer URL Vobiz calls. The default is the shared demo server, only usable in demo mode |
| `voiceApiUrl` | `SdkConfig.defaultVoiceApiUrl` = `https://api.vobiz.ai` | The Vobiz API the webhook server calls for you |
| `autoReconnect` | `true` | Reconnect with backoff (1, 2, 4, 8, 16 s, then every 30 s) |
| `debug` | `false` | SDK logs to the console |
| `iceConfig` | Google STUN | Add TURN for restrictive networks |
| `mediaConstraints` | audio with echo cancellation, noise suppression, AGC | |
| `unsafeDemoZeroConfig` | `false` | **Demo only.** Allows `connectWithAuthToken`, `transferCall` and the demo server's recordings, which send or expose account credentials. Never ship with it set |
| `reregisterOnForeground` | `true` | Re-register (or reconnect) each time the app returns to the foreground; see [Returning to the foreground](#returning-to-the-foreground) |

## VobizSipHeaders

The custom-header rules, identical to the Vobiz web SDK's:

- Names: `X-VH-` plus 1-19 letters, digits or hyphens; or `X-Vobiz-JWT`.
- Values: `A-Z a-z 0-9 _ - + ( ) % .`, no spaces, up to 120 characters (500 for the JWT).

| Member | |
|---|---|
| `prefix`, `jwt`, `record`, `dialUser`, `callerId` | Header names |
| `String? validateName(String)`, `String? validateValue(String name, String value)` | A reason, or null when valid |
| `HeaderCheck check(Map<String, String>)` | `valid` headers and one `errors` line per rejected one (duplicates are case-insensitive) |
| `Map<String, String> pick(Map<String, String>)` | Only the valid custom headers, as an incoming call reports them |
| `XmlSipHeaders toXml(Map<String, String>)` | The `sipHeaders` attribute value (`OrderId=A1234,…`) and the headers that cannot be expressed in it |

## Models

| Type | Fields |
|---|---|
| `ZeroConfigSession` | `sipUsername`, `sipPassword`, `applicationId`, `message`, `reusedExisting` |
| `VobizRecording` | `recordingId`, `callUuid`, `url`, `durationSecs`, `endReason`, `receivedAt` |
| `CallStats` | `rttMs`, `jitterMs`, `packetLossPercent` |
| `CredentialConfig` | `username`, `password`, `displayName`, `answerUrl` |
| `TokenConfig` (deprecated) | `token` (sent as the SIP password), `displayName` (used as the SIP username), `answerUrl`. Not a JWT: for one use `connectWithAccessToken` |
| `VobizAccessToken` | `VobizAccessToken.parse(token)`; `token`, `sipUsername`, `accountId`, `subject`, `appId`, `notBefore`, `expiresAt`, `incomingAllowed`, `outgoingAllowed`, `canCallOut`, `canReceiveCalls`, `isExpired()`, `timeLeft()`. `toString()` never prints the token |
| `CallSession` | `currentCall`/`calls`/`CallEvent.session`: `callId`, `remoteIdentity`, `isIncoming`, `state`, `callUuid`, `headers`, `actions` (`CallActions`) |
| `Logger` | `Logger({LogWriter? writer})`: pass to `VobizClient(logger:)` to receive SDK log lines |

## Enums

| Enum | Values |
|---|---|
| `VobizAuthMode` | `none`, `zeroConfig`, `sipDirect` (also after `connectWithCredentialsProvider`), `accessToken` (`connectWithAccessToken` and `connectWithAccessTokenProvider`) |
| `VobizCredentialsRequest` | `signIn`, `rejected`, `refresh` |
| `VobizPushKind` | `incomingCall`, `callEnded` |
| `CallStateStatus` | `idle`, `incoming`, `outgoing`, `ringing`, `connecting`, `active`, `held`, `ended`, `failed` |
| `CallDirection` | `inbound`, `outbound` |
| `TransferLeg` | `aLeg` (`aleg`: move yourself), `bLeg` (`bleg`: move the other party) |
| `ConnectionStateStatus` | `disconnected`, `connecting`, `connected`, `reconnecting`, `failed` |
| `RegistrationState` | `unregistered`, `registering`, `registered`, `failed` |
| `DtmfTone` | `digit0` … `digit9`, `star`, `hash` |
