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
| `VobizAuthMode authMode` | `none`, `zeroConfig` or `sipDirect` |
| `String? sipUsername` | The endpoint this client registers as |
| `bool isConnected` | Socket connected and registered |
| `RegistrationState registrationState`, `ConnectionStateStatus connectionState` | |
| `String backendUrl` | The webhook server. Mutable: set it before signing in to use another one |

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
| `Future<void> sendDtmf(String digits)` | `0-9 * # A-D`, sent as `application/dtmf-relay` SIP INFO, 500 ms apart. `StateError` without a connected call |
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

`hold`, `resume`, `transfer(String to)`, `warmTransferStart`, `warmTransferComplete`,
`addCall`, `startSecondCall`, `swapCalls`, `mergeCalls`, `endSecondCall` and
`removeAddedCall` call routes such as `/hold-start` on `backendUrl`. Only the Node
reference server implements them.

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
`credentialsFailed`.

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
- Once the client has registered again on a new connection, it restarts ICE: new ICE
  credentials and candidates gathered on the network the device has now, offered to
  Vobiz in an in-dialog re-INVITE on that connection. Vobiz then sends the call's later
  requests (the far end's BYE, say) to the new connection. The grace period starts
  again with the restart, so gathering, the re-INVITE and the ICE checks get the full
  12 s.
- When ICE connects the call gets `reason: 'reconnected'`. If it is not back in time
  the call ends with reason `network_lost` and an `ErrorEvent` `network_lost`.
- Measured on Android against Vobiz: the audio is back about 1.4 s after the network
  returns, and a switch between Wi-Fi and mobile data leaves a gap of about 2 s.

A device that stays offline cannot tell Vobiz that it gave up: its BYE never leaves
the phone, and Vobiz keeps the other party connected, and billed, until its media
servers time the call out (300 s in our tests). The example's push bridge shows one way
to end such calls from a server (example/push_bridge/README.md, "Connection watch").

## Errors

| Type | Code | Thrown when |
|---|---|---|
| `VobizException` | any | Base class: `code`, `message`, `statusCode`, `cause` |
| `VobizDemoModeRequiredException` | `demo_mode_required` | An Auth-Token operation without `unsafeDemoZeroConfig` |
| `VobizCredentialsException` | `credentials_failed` | Your credentials provider (or backend) failed |
| `VobizRegistrationException` | `registration_failed` | The registrar kept refusing fresh credentials (on `VobizCredentialsSession.failures`) |

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
| `TokenConfig` (deprecated) | `token` (sent as the SIP password), `displayName` (used as the SIP username), `answerUrl` |
| `CallSession` | `currentCall`/`calls`/`CallEvent.session`: `callId`, `remoteIdentity`, `isIncoming`, `state`, `callUuid`, `headers`, `actions` (`CallActions`) |
| `Logger` | `Logger({LogWriter? writer})`: pass to `VobizClient(logger:)` to receive SDK log lines |

## Enums

| Enum | Values |
|---|---|
| `VobizAuthMode` | `none`, `zeroConfig`, `sipDirect` (also after `connectWithCredentialsProvider`) |
| `VobizCredentialsRequest` | `signIn`, `rejected`, `refresh` |
| `VobizPushKind` | `incomingCall`, `callEnded` |
| `CallStateStatus` | `idle`, `incoming`, `outgoing`, `ringing`, `connecting`, `active`, `held`, `ended`, `failed` |
| `CallDirection` | `inbound`, `outbound` |
| `TransferLeg` | `aLeg` (`aleg`: move yourself), `bLeg` (`bleg`: move the other party) |
| `ConnectionStateStatus` | `disconnected`, `connecting`, `connected`, `reconnecting`, `failed` |
| `RegistrationState` | `unregistered`, `registering`, `registered`, `failed` |
| `DtmfTone` | `digit0` … `digit9`, `star`, `hash` |
