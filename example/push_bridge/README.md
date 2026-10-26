# Push bridge: inbound calls for the example app

A small server that answers your Vobiz number and rings the example app for every
inbound call, also when the app is in the background or has been swiped away from
Recents. Node 18 or newer, no npm packages, one file: `push-bridge.mjs`.

## Why the app needs it

The app registers with Vobiz over a WebSocket. When Android closes the app, the
socket closes and Vobiz removes the registration at once, so an inbound call has
nothing left to ring. A phone app wakes up for calls through a push message, and
something has to send that push: this bridge.

```
caller ──> your Vobiz number ──> Vobiz ──> POST /answer on this bridge
                                              │
             ┌────────────────────────────────┴────────────────────────────┐
             │ 1. a Firebase push to the routed endpoints' phones           │
             │ 2. the caller hears ringback (early media) for up to         │
             │    PUSH_WAIT_SECONDS while the phones wake and sign in:      │
             │    <PreAnswer><Play>wait.wav</Play></PreAnswer>              │
             │    <Redirect>/dial-now/…</Redirect>                          │
             │ 3. every pushed phone reports POST /push/registered          │
             │      → the caller is transferred to /dial-now at once        │
             │    or the wait ends first → the Redirect reaches /dial-now   │
             │ 4. ONE <Dial> rings everyone at once: the app endpoints,     │
             │    ALWAYS_RING endpoints (e.g. a browser) and the route's    │
             │    PSTN <Number>s. First to answer wins; Vobiz cancels the   │
             │    rest. It is never restarted.                              │
             └──────────────────────────────────────────────────────────────┘
user taps Accept ──> the INVITE (PushRef = call_id) is answered by the app
user taps Decline ──> app tells the bridge ──> caller hears busy, other phones stop
another target answers ──> a push stops the phones (answered_elsewhere)
app signs in after the Dial started ──> "too_late": the others keep ringing, and
                                        the app's screen closes on call_ended
caller hangs up ──> Vobiz calls /hangup ──> a push stops the phones ringing
```

Nothing to wake (no routed phone has a push token, or the endpoint is already on a
call through the bridge): no wait, the Dial starts at once.

**Which app endpoints are in the Dial:** every routed endpoint, whether or not its
app reported in time. An app that is open but did not report still rings; an
offline one only fails its own leg. An app that signs in after the Dial started is
not added: the Dial is not restarted, so a ringing browser or phone is not cut off.
With only app endpoints on a route (no browser, no number), the call therefore
depends on the app signing in within `PUSH_WAIT_SECONDS`; raise it (up to 9) if
your phones are slow to wake.

## What you need

- **Node 18+** (`node --version`).
- **A Firebase project** with an Android app whose package name is
  `ai.vobiz.vobiz_webrtc_example`. Download its `google-services.json` into
  `example/android/app/` (it is git-ignored) and rebuild the app.
- **A service account key** for the same Firebase project: Firebase console →
  Project settings → Service accounts → *Generate new private key*. Keep the JSON file
  outside the repository, or in this folder under a name the `.gitignore` covers.
- **A public HTTPS address** for this server, so Vobiz can reach it, for example
  `cloudflared tunnel --url http://localhost:8787` or `ngrok http 8787`.
- **A Vobiz number** on the same account as the endpoint the app signs in with.

## Run it

```bash
cd example/push_bridge
cp .env.example .env        # then fill it in: PUBLIC_URL, FIREBASE_SERVICE_ACCOUNT, VOBIZ_*
node push-bridge.mjs        # or: npm start
npm test                    # node:test, local fakes only: no Vobiz or Firebase calls
```

It will not start without an `https://` `PUBLIC_URL` and `VOBIZ_AUTH_TOKEN`: both
go into every Vobiz webhook signature, and without them anyone who finds the
tunnel could ring your phones. For a local experiment only,
`ALLOW_UNSIGNED_WEBHOOKS=true` starts it anyway and says so in the log.

On start-up it checks everything and says what it found:

```
[18:10:02] ok Vobiz push bridge listening on http://localhost:8787
[18:10:03] ok Firebase: service account for project my-project works
[18:10:03] ok Tunnel: https://example.trycloudflare.com reaches this server
[18:10:04] ok Vobiz: application Vobiz_Flutter_Push_Bridge now answers at https://example.trycloudflare.com/answer
[18:10:04] ok Vobiz: +919876543210 now rings this bridge
[18:10:04] ok Webhooks: Vobiz signatures (V3/V2) and nonces are checked
[18:10:04] .. Phones registered: none yet

  Pair a phone: Identity tab → Incoming calls → Push server, paste this line:

    https://example.trycloudflare.com#key=…
```

The pairing line is printed once, when the bridge key is created. Later it is
`bridgeKey` in `bridge-state.json` (readable by your user only) or your
`BRIDGE_KEY`.

With `VOBIZ_AUTH_ID`, `VOBIZ_AUTH_TOKEN` and `VOBIZ_NUMBER` set, the bridge creates
(or updates) the application `Vobiz_Flutter_Push_Bridge` with its answer and hangup
URLs and attaches the number to it. It will not take a number that another
application already has unless `FORCE_ATTACH=true`. Without those settings, create
the application yourself in the Vobiz Console with answer URL `<PUBLIC_URL>/answer`
and hangup URL `<PUBLIC_URL>/hangup` (both POST), and attach the number.

A quick tunnel gets a new address each time it starts. Put the new one in
`PUBLIC_URL`, restart the bridge (it re-points the application), and change the
address in the app; the phone keeps its device token.

**More than one endpoint?** Set `ROUTES` so each number rings only its own
endpoints, e.g. `ROUTES=+919876543210=alice;+918000000000=bob,carol`. Without
`ROUTES` the bridge rings the one endpoint that has registered a phone; if phones
are registered for several endpoints it rings none of them and says so in the log.

**Ring a phone number as well:** an entry of `+` and digits (E.164) in a route is a
PSTN number, rung with `<Number>` in the same Dial:
`ROUTES=+918000000000=alice,bob,+919876543210`. Endpoint names keep working as
before. The PSTN leg shows the dialled Vobiz number as caller ID
(`CALLER_ID_MODE=number`, the default); with `CALLER_ID_MODE=caller` no `callerId` is
sent and Vobiz derives it from the caller, which the carrier may refuse for an
outbound leg. PSTN legs are billed as outbound calls.

## In the app

1. Sign in once with **Remember me** ticked: with the app closed, accepting a call
   makes it sign itself in with what was saved.
2. Identity tab → **Incoming calls**: paste the line, switch on **Receive calls through
   the push server**, and allow notifications (and full-screen notifications, if
   Android asks).
3. The chip reads **PUSH ON** once the bridge has this phone's Firebase token. Without
   `google-services.json` it reads **RINGS WHEN OPEN**: calls still ring while the app
   is open, but a closed app is not woken.
4. **Send a test call in 10 s** asks the bridge for a pretend call: press Home, or
   swipe the app away, and the call screen appears. Nothing connects; it proves the
   push path.

Disconnecting in the app unregisters the phone; closing the app does not.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8787` | Port to listen on |
| `PUBLIC_URL` | — | This server's public HTTPS address (from the tunnel) |
| `FIREBASE_SERVICE_ACCOUNT` | — | Path to the Firebase service account key |
| `VOBIZ_AUTH_ID`, `VOBIZ_AUTH_TOKEN` | — | Your account, to link the number and check webhook signatures |
| `VOBIZ_NUMBER` | — | The number to point at this bridge, in E.164 |
| `VOBIZ_APP_NAME` | `Vobiz_Flutter_Push_Bridge` | Name of the application it finds or creates |
| `FORCE_ATTACH` | `false` | Move the number here even if another application has it |
| `RING_SECONDS` | `45` | How long the one Dial rings (its `timeout`) |
| `PUSH_WAIT_SECONDS` | `5` | How long the caller hears ringback while pushed phones wake and sign in, before the Dial starts without them. Clamped to 3–9 |
| `CALLER_ID_MODE` | `number` | `number`: the app's SIP call shows your Vobiz number, as the web Playground does. `caller`: pass the real caller through |
| `SIP_HEADER_STYLE` | `suffix` | How the call reference is written in `<User sipHeaders>`; Vobiz's docs show both `RefX-VH=` and `Ref=` |
| `ROUTES` | — | Which endpoints (and PSTN numbers) each number rings: `+91…=alice,bob,+9198…;+91…=carol` |
| `ALWAYS_RING` | — | Endpoints to ring even if no app registered, comma separated (not pushed) |
| `BRIDGE_KEY` | generated | The pairing key; saved in `bridge-state.json` |
| `ALLOW_UNSIGNED_WEBHOOKS` | `false` | `true` accepts webhooks without a Vobiz signature. Local tests only |
| `LOST_BEEP_SECONDS` | `3` | Connection watch: seconds without an "alive" report from the app before the other party hears the connection-lost beep. Clamped to 2–10 |
| `LOST_HANGUP_SECONDS` | `15` | Connection watch: seconds without a report before the bridge ends the call (the SDK gives up at 12 s, but an offline phone's hangup cannot reach Vobiz). Clamped to 5–300; `0` never ends it |
| `JWT_SUB` | `flutter-app` | Access tokens: the user id (`sub`) `POST /token` mints for when the app sends none. The app registers as `<sub>_<VOBIZ_AUTH_ID>` |
| `JWT_TTL_SECONDS` | `3600` | Access tokens: lifetime, clamped to 180–86400 (the platform's limits). The SDK renews 60 s before expiry |
| `JWT_APP_ID` | — | Access tokens: the application whose Answer URL handles the app's outbound calls (the `app` claim). Without it, the account's default application. The bridge's own application only rings phones, so point this at the one your outbound calls use (the Playground application, for example) |

Whatever the caller ID mode, the push shows the real caller, and the bridge passes
the real caller to the app in a SIP header as well.

## Routes

| Route | Called by | Purpose |
|---|---|---|
| `POST /answer` | Vobiz | An inbound call: push the phones, hold the caller on ringback (or dial at once if nothing is pushed) |
| `POST /dial-result/<call>.<tag>` | Vobiz | The Dial ended: hang up (answered, missed, busy, declined). Never dials again |
| `POST /dial-events/<call>.<tag>` | Vobiz | Live events for the leg ringing the app. Only an answer event here counts as answered: Vobiz can report `DialStatus=completed` for a ring nobody picked up |
| `POST /dial-now/<call>.<tag>` | Vobiz | The one Dial: reached by the hold's `<Redirect>` when the wait ends, or by a transfer when the pushed phones report they are registered |
| `POST /declined/<call>.<tag>` | Vobiz | The caller's leg, transferred here on Decline: busy tone, then busy |
| `POST /token` | the app | An access token (JWT) for signing in: minted with `POST /Account/{auth id}/JWT/Token/`, the Auth Token staying here. Bridge key or device token; `sub` from the body or `?sub=`, else `JWT_SUB`. Replies `{token, sub, exp, sip_username}`, as the Vobiz WebRTC demo's `/token` does |
| `POST /hangup` | Vobiz | The caller's leg ended: stop the phones ringing |
| `GET /wait.wav`, `/busy.wav` | Vobiz | `PUSH_WAIT_SECONDS` of ringback / three seconds of busy tone |
| `GET /lost.wav` | Vobiz | The connection-lost beep: 0.25 s of 1 kHz in 2.5 s, played looped |
| `POST /call/alive` | the app | During a call, every second: this phone still has its network (device token, `call_uuid`) |
| `POST /call/ended` | the app | The call ended in the app: stop watching it (device token, `call_uuid`) |
| `POST /dtmf-test` | Vobiz | DTMF test: an answer URL that asks for four digits (`<Gather>`) |
| `POST /dtmf-test-digits` | Vobiz | DTMF test: logs the digits Vobiz received and reads them back |
| `POST /push/register` | the app | Pair (bridge key) or update (device token) this phone |
| `POST /push/unregister`, `/push/test` | the app | Forget / test-push this phone (device token) |
| `POST /push/registered` | the app | The app's SIP registration succeeded: end the wait and dial now (call key or device token) |
| `POST /push/accept`, `/push/decline` | the app | The user's answer (needs that call's key from the push) |
| `GET /health` | anyone | `{"ok": true}` |

Every Vobiz route needs a valid signature. `<call>.<tag>` is the Vobiz CallUUID and
an HMAC the bridge made, so the signed URL (Vobiz signs the URL, not the body or
query string) names the call.

## Access tokens

The example's **Access token** tab signs in with a short-lived JWT instead of an
endpoint password. With its token server left empty it asks this bridge:

1. `POST /token` (bridge key, or the phone's device token once paired) mints
   `{"iss": VOBIZ_AUTH_ID, "sub": <user id or JWT_SUB>, "nbf", "exp", "per": {"voice":
   {"incoming_allow": true, "outgoing_allow": true}}, "app": JWT_APP_ID}` through the Vobiz
   API. The Auth Token never leaves the bridge. `nbf` is a minute in the past, because
   the registrar refuses a token whose `nbf` its clock has not reached (10005); `sub` is
   letters, digits, `_` or `-`, at most 50. Set `JWT_APP_ID`: a token without `app` can
   be refused with 10001 (the bridge warns once).
2. The SDK registers as `<sub>_<VOBIZ_AUTH_ID>` with the token in `X-Vobiz-Jwt`, and asks
   for the next token a minute before this one expires.
3. "Receive calls" registers that identity here like an endpoint: the bridge accepts
   `<sub>_<VOBIZ_AUTH_ID>` (an identity the token creates; it is not in the Console), and
   rings it as `<User>sip:<sub>_<VOBIZ_AUTH_ID>@registrar.vobiz.ai</User>`. List it in
   `ROUTES` like an endpoint when several users have phones.

Outbound calls go to the token's `app`: set `JWT_APP_ID` to the application whose Answer
URL dials out for you. Like the demo's, this route trusts whoever holds the bridge key;
in production, issue tokens only after your own user has signed in, with that user's id
as `sub`.

## Connection watch

A phone that loses its network cannot tell anyone, and the other party just hears
silence. So during a call the app reports `POST /call/alive` every second. When the
reports stop for `LOST_BEEP_SECONDS`, the bridge (still online) has Vobiz play
`/lost.wav` to the other party, looped, so they hear a beep every 2.5 s. The beep
stops when the app reports again (the SDK restarts ICE once the network is back).

The SDK ends a call that is not back within 12 s, but the BYE cannot leave an offline
phone, and Vobiz then keeps the call up, and billed, for about five minutes (tested:
its WebRTC server ends it 300 s after the last audio, recorded as a normal hangup).
So after `LOST_HANGUP_SECONDS` without a report the bridge ends the call itself.

The first report of a call is checked against Vobiz's live call: the bridge acts only
on calls of the phone's own endpoint. The app sends reports only while "Receive calls"
is on, since it needs this bridge and the phone's device token.

## DTMF test

The SDK sends keypad presses as RFC 4733 telephone-events, which a phone on the other
end does not hear as tones. To check that they reach Vobiz, call the app through the
Vobiz API with this bridge as the answer URL, answer, and press four digits:

```bash
curl -X POST "https://api.vobiz.ai/api/v1/Account/$VOBIZ_AUTH_ID/Call/" \
  -H "X-Auth-ID: $VOBIZ_AUTH_ID" -H "X-Auth-Token: $VOBIZ_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"from": "<your Vobiz number, no +>", "to": "sip:<endpoint>@registrar.vobiz.ai",
       "answer_url": "'"$PUBLIC_URL"'/dtmf-test", "answer_method": "POST"}'
```

The bridge logs `Vobiz received "1234"` and reads the digits back to the caller.

## App ↔ bridge protocol

All app requests are JSON `POST`s. `<device_token>` is what pairing returned.

| Request | Auth | Body | Response |
|---|---|---|---|
| `/push/register` (pair) | `X-Bridge-Key: <bridge key>` | `{username, token?, platform?, app?}` | `{ok, username, push, device_id, device_token}`. Store `device_token`; it is shown only once. 401 bad key, 403 username is not an endpoint on the account, 503 Vobiz could not be asked |
| `/push/register` (update, e.g. new FCM token or username) | `Authorization: Bearer <device_token>` | same | `{ok, username, push, device_id}` |
| `/push/unregister` | `Authorization: Bearer <device_token>` | `{}` | `{ok}`; the device token stops working |
| `/push/test` | `Authorization: Bearer <device_token>` | `{delay_seconds?}` | `{ok, call_id, sending_in_seconds}`; pushes this phone only |
| `/push/registered` | none (call key) | `{call_id, call_key}` | `{ok, redial, finished}`. `redial`: `transferred` (the Dial starts now), `waiting` (it starts when the wait ends, this phone included: other pushed phones have not reported, the wait ends within a second, or the transfer failed), `too_late` (the Dial had started; it is not restarted, and `call_ended` closes this phone's screen), `finished`, `test`. `next_attempt` is no longer sent |
| `/push/registered` | `Authorization: Bearer <device_token>` | `{}` | `{ok, calls: {<call_id>: …}}` for every call ringing this endpoint |
| `/push/accept` | none (call key) | `{call_id, call_key}` | `{ok, test}`, or `{ok, finished: true, reason}` if the call is over |
| `/push/decline` | none (call key) | `{call_id, call_key}` | `{ok, busy: "transferred" \| "next_attempt"}` (`next_attempt`: the transfer failed; busy plays at the end of the wait or the Dial result), or `{ok, finished: true}`. There is no decline by username or caller number any more |

Push messages (FCM data, all values strings):

- `incoming_call`: `call_id`, `call_key`, `caller`, `callee`, `server`, `sent_at`,
  **`ttl_ms`** (milliseconds the call can still ring when the bridge sent it: the push
  wait plus `RING_SECONDS`; expire
  the call screen `ttl_ms` after the push arrives, never by comparing `expires_at`
  with the phone's clock), `expires_at` (bridge clock, for older builds only),
  `line_busy: "1"` when the endpoint is already on a call through the bridge (show
  call waiting, not the full-screen ringing screen), `test: "1"` for test calls.
- `call_ended`: `call_id`, `reason`: `caller_hung_up`, `answered_elsewhere` (with
  `answered_by` when Vobiz names the endpoint), `declined`, `missed`, `busy`,
  `completed`. A phone already in the call (SIP `PushRef` = `call_id`) ignores
  `answered_elsewhere`; any other phone stops ringing without a missed-call entry.

The SIP INVITE for a pushed call carries a `PushRef` header (written `PushRefX-VH=`
or `PushRef=` in `<User sipHeaders>`, see `SIP_HEADER_STYLE`) equal to `call_id`, on
every `<User>` of the Dial. The app should auto-answer an
accepted call only when `PushRef` equals that `call_id`, never by caller or callee
number. The app should call `/push/registered` as soon as its REGISTER gets a 200
while a pushed call is ringing, and also when the push arrives while it is already
registered (otherwise the caller waits the whole `PUSH_WAIT_SECONDS`). The bridge
dials once every pushed phone has reported; with the call key it cannot tell phones
apart, so it counts reports.

## Security

- Webhooks fail closed: every Vobiz request needs a valid V3 (or V2) signature over
  `PUBLIC_URL` + path, and each nonce is accepted once (remembered for 30 minutes,
  across restarts). Vobiz nonces are random and nothing is timestamped, so there is
  no clock-based freshness check. Vobiz signs only callback URLs that have
  credentials configured; if your log shows "no X-Vobiz-Signature headers", set
  them on the application.
- The bridge key only pairs a phone. Each phone then has its own device token (the
  bridge stores a hash), and can only update, test or remove itself. With
  `VOBIZ_AUTH_ID` set, only endpoints on your account can be registered.
- Calls are pushed only to the phones of the endpoints that number rings.
- Accept, decline and "registered" need the per-call key that only those phones
  receive.
- `bridge-state.json` (bridge key, device hashes, push tokens, nonces) is written
  `0600`. `.env`, `bridge-state.json` and service account keys are git-ignored. Do
  not commit them.
- Not done: proving that a phone holds the endpoint's SIP password. Whoever has the
  bridge key can still pair a phone for any endpoint on the account, so treat the
  key like a password.

## Limits

- Android only. iOS needs PushKit and an APNs VoIP certificate, which this example
  does not set up.
- Decline: `<Hangup reason="busy">` rejects a call unbilled only while it is
  unanswered. Whether the caller's leg is already answered (and billed) once the
  `<Dial>` has run has not been checked on a CDR yet; the caller hears a busy
  tone either way.
- Not checked live yet: whether the Vobiz Transfer API moves a call that is still in
  `<PreAnswer>` early media (its docs say a call must be `in-progress`), and whether
  the hold's `<Redirect>` answers the caller's leg. If the transfer is refused, the
  reply is `waiting` and the Dial starts when the wait ends: correct, only not early.
  The transfer needs `VOBIZ_AUTH_ID`; it is not attempted in the wait's last second,
  so it cannot cross the `<Redirect>`.
- Carriers that ignore early media play the hold as ordinary audio once the call is
  answered (Vobiz docs: `/xml/preanswer`).
- Calls in progress live in memory: restarting the bridge mid-call drops them.
- Swiping the app from Recents is fine; **Force stop** (Settings → Apps) is not:
  Android delivers no push to a force-stopped app until it is opened again.
- Some Android makers stop pushes to apps swiped from Recents unless the app may run
  in the background (battery optimisation, "autostart"). Pixel and the emulator do not.
- If Firebase's push arrives late, or the app takes longer than `PUSH_WAIT_SECONDS`
  to sign in, the Dial starts without it and its leg fails; the other targets still
  ring, and the next inbound call is unaffected.
