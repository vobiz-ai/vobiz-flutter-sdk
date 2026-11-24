# Incoming calls to a closed app: how Vobiz push works

The SDK registers over a WebSocket. When Android suspends or kills the app, the socket
closes, but the registration the app left behind stays on Vobiz's registrar until it
expires: the SDK asks for an hour (`Expires: 3600`), and every REGISTER (sign-in, the
refresh at 80 % of the lifetime, the return to the foreground, the claim of a pushed
call) starts the hour again. While that registration lasts, a call to its SIP user is
held and pushed instead of being refused. On iOS the push is a PushKit VoIP push; see
[iOS](#ios).

## The flow

```
caller ──> Vobiz ──> registrar: the SIP user's registration is left behind, its socket gone
                       │  holds the call (up to 30 s)
                       ▼
                     Vobiz push service ──> Firebase ──> every phone signed up for that SIP user
                                                           │
   app wakes, shows its call screen, hands the push to     │
   client.handleIncomingPush(push) and signs in   <────────┘
                       │  REGISTER with X-Index, X-Label, X-vobiz-Registrar-Info
                       ▼
                     registrar sends the held INVITE to this registration,
                     with the push's call_id as its Call-ID
                       │
                       ▼
   the SDK reports it as an incoming call (CallEvent.sipCallId == push.callId),
   and answers or declines it if the call screen's button was already pressed
```

1. **Sign-up.** After each sign-in, and whenever Firebase replaces the token, the app
   signs the phone up for its SIP user with `VobizPushDevices.register`, through its own
   backend ([CREDENTIALS.md](../CREDENTIALS.md#push-sign-up-through-your-backend)). At
   sign-out, `VobizPushDevices.logout`.
2. **Hold and push.** A call for that SIP user finds the registration left behind. The
   registrar holds the call and Vobiz's push service sends a Firebase data message to the
   phones signed up for the user:

   ```json
   {"type": "incoming_call", "call_id": "<SIP Call-ID>", "call_uuid": "...",
    "caller": "...", "caller_number": "+91...", "callee": "<SIP user>",
    "index": "...", "label": "...", "registrar": "...",
    "expires_at": "1762900030"}
   ```

   `expires_at` is Unix seconds.
3. **Claim.** The app reads it with `VobizIncomingPush.tryParse(data)` and hands it to
   `client.handleIncomingPush(push)`. The next REGISTER carries the hold reference
   (`index`, `label` and `registrar` as `X-Index`, `X-Label` and
   `X-vobiz-Registrar-Info`): at once if the app is still signed in and registered, after
   an immediate reconnect if it is signed in but between connections, or as part of the
   sign-in the app starts next. Only that one REGISTER carries it.
4. **Delivery.** The registrar sends the held INVITE to the registration that claimed it,
   with the push's `call_id` as its Call-ID. The SDK ties the two by that Call-ID only,
   never by the caller's number, so another call from the same person is never answered
   in its place.
5. **Call screen.** `reportCallScreenAccepted(push)` answers the call as soon as its
   INVITE arrives (at once if it is already ringing); `reportCallScreenDeclined(push)`
   declines it (486). `pushCallUpdates` reports `claiming`, `claimed`, `ringing`,
   `answering` or `declining`, and `expired` when no INVITE came in time.

## In the app

```dart
// Firebase message handler (the app may have been started just for this).
final push = VobizIncomingPush.tryParse(message.data);
if (push == null) return;                     // not Vobiz's incoming-call push
if (!client.handleIncomingPush(push)) return; // expired: do not ring
showCallScreen(caller: push.caller, id: push.callId);
if (client.sipUsername == null) {
  // Closed app: sign in now, from cached credentials (no round trip to your
  // backend first). This sign-in's REGISTER claims the call.
  await client.connectWithCredentialsProvider(cachedProvider);
}

// Call-screen buttons:
onAccept: () => client.reportCallScreenAccepted(push);
onDecline: () => client.reportCallScreenDeclined(push);

// Take the screen down when the call never came, or ended:
client.pushCallUpdates.listen((u) {
  if (u.status == VobizPushCallStatus.expired) hideCallScreen(u.push.callId);
});
client.callEvents.listen((e) {
  if (client.isPushedCall(e.callId) && e.state == CallStateStatus.ended) hideCallScreen(e.callId);
});
```

The SDK has no Firebase or call-screen dependency: the app receives the push, shows the
screen and keeps the call alive with a foreground service
([PLATFORM_SETUP.md](../PLATFORM_SETUP.md#keep-a-call-alive-in-the-background)). The
example app does all of it (`example/lib/src/push/`, and `CallPushReceiver.kt`, which
hands the push to the app's one Flutter engine, starting it without a screen when the
app is closed).

## Rules and limits

- **Reachable while the registration lasts.** A closed phone rings only while the
  registration it left behind lasts (an hour from its last REGISTER) and only if it is
  signed up. After that, or after a sign-out (REGISTER `Expires: 0`), the call fails at
  once for that phone and nothing is pushed.
- **The registrar holds a call for up to 30 seconds.** The claim has to reach it in that
  time, so sign in from cached credentials and start nothing slow before it. A
  `<Dial>` that rings the user should ring for longer than that (the example's sample
  server defaults to 45 s).
- **Clocks.** `expires_at` is set by Vobiz's clock and read by the phone's. The SDK still
  acts on a push until 30 s past `expires_at`, and awaits its call at most 60 s after the
  push was handed over (30 s for a push without `expires_at`). `handleIncomingPush`
  returns false for a push older than that.
- **Decline claims first.** A held call cannot be declined without claiming it, so
  Decline still sends the claiming REGISTER and then declines the INVITE with 486 on
  this phone's leg. Other phones rung for the same call keep ringing.
- **No stop-ringing message.** Nothing tells the app that the caller gave up, or that
  another phone answered, before the INVITE arrived: the call screen comes down when the
  push expires (`expired`). Once the INVITE has arrived, the caller's CANCEL ends the
  call as usual.
- **Android delivery.** Android delivers no push to an app that was force-stopped from
  Settings until it is opened again; swiping it from Recents is fine. Some phone makers
  also stop pushes to apps swiped from Recents unless the app may run in the background.
- **Testing.** `client.disconnect(unregister: false)` closes the connection without
  unregistering, as when Android kills the app, so a call placed right after takes the
  push path. The example's *Call this phone through Vobiz* (debug builds) does that and
  then calls the phone's own SIP user through Vobiz's Call API.

## iOS

The flow is Android's, with PushKit in place of Firebase and CallKit as the call screen:

- Vobiz's push service sends an APNs VoIP push (topic `<bundle id>.voip`, 30 s expiry)
  to the devices signed up with `platform: ios`, `push_type: voip`. The call's fields
  (`type`, `call_id`, `index`, `label`, `registrar`, `expires_at`, …) are top-level keys
  of the payload, next to `aps`.
- The app's `PKPushRegistry` delegate reports the call to CallKit before calling
  PushKit's completion, for **every** push, then hands the fields to Dart, which calls
  `handleIncomingPush` and signs in. The REGISTER that claims the call is the same.
- Accept and Decline on CallKit are `reportCallScreenAccepted` and
  `reportCallScreenDeclined`. An answered call stays on CallKit until it ends.
- WebRTC's audio waits for CallKit to activate the audio session.

The example does all of it; [PLATFORM_SETUP.md](../PLATFORM_SETUP.md#incoming-calls-on-ios-pushkit-and-callkit)
lists the steps. CallKit's mute button and the app's
stay in step, and missed calls are local notifications (asked for once the phone signs
up for push). Not done yet: outgoing calls are not reported to CallKit; they run in the
app, kept alive in the background by the `audio` background mode.
