# Sample server for the example app

A small server for the Flutter example app. Node 22 or newer, no npm packages, one
file: `push-bridge.mjs` (the folder keeps its old name). It:

- **answers your Vobiz number** and rings, at once and in one `<Dial>`, the SIP users
  and phone numbers you list for it;
- **mints access tokens** (JWT) for the app with your Auth Token, which stays on the
  server;
- **signs the phone up for Vobiz push**, so a closed app can be woken for calls
  without the phone ever holding your Auth Token;
- **runs conferences**: the app's **Add** button turns its call into a conference;
- **watches the app's connection** during a call, when the app is set to report.

It does not wake a closed app itself. Vobiz does: when a SIP user whose app is closed
is called, Vobiz's registrar holds that leg (up to 30 seconds), pushes the phones
signed up for that user, and hands the call to the app once it has signed in and
claimed it. A closed app keeps its registration until it expires (the SDK asks for
3600 seconds); after that, or when signed out, its leg fails at once.

```
caller ──> your Vobiz number ──> Vobiz ──> POST /answer on this server
                                              │
                                              └─> ONE <Dial> rings everyone at once:
                                                  the ROUTES users for that number,
                                                  the ALWAYS_RING users, the route's
                                                  phone numbers. First to answer wins;
                                                  Vobiz cancels the rest.

a ringing app with the app open ───────> rings over SIP
a ringing app that is closed ──────────> Vobiz holds the leg and pushes the phone
user taps Decline ─────────────────────> SIP 486 on that phone's leg only; the
                                         others keep ringing
nobody answers ────────────────────────> "Sorry, there was no answer"
everyone rung is on a call this server
connected (their apps refuse with 486) > busy tone
```

## What you need

- **Node 22+** (`node --version`).
- **A public HTTPS address** for this server, so Vobiz can reach it, for example
  `cloudflared tunnel --url http://localhost:8787` or `ngrok http 8787`.
- **A Vobiz number** on the same account as the SIP users the app signs in as.
- **For calls to a closed app:** the app built with its `google-services.json`
  (package `ai.vobiz.vobiz_webrtc_example`), and that Firebase project's key saved
  under Push Notifications in the Vobiz Console. The server needs no Firebase key.

**Upgrading from the push version:** this server no longer uses a Firebase service
account. Delete the key file (and `FIREBASE_SERVICE_ACCOUNT` from `.env`), and revoke
the key in the Firebase console (Project settings → Service accounts). The first start
drops the old phones' push tokens from `bridge-state.json`; `PUSH_WAIT_SECONDS` is no
longer read.

## Run it

```bash
cd example/push_bridge
cp .env.example .env        # then fill it in: PUBLIC_URL, VOBIZ_*, ROUTES
node push-bridge.mjs        # or: npm start
npm test                    # node:test, local fakes only: no Vobiz calls
```

It will not start without an `https://` `PUBLIC_URL` and `VOBIZ_AUTH_TOKEN`: both
go into every Vobiz webhook signature, and without them anyone who finds the
tunnel could ring your phones. For a local experiment only,
`ALLOW_UNSIGNED_WEBHOOKS=true` starts it anyway and says so in the log.

In `.env`, each description goes on its own `#` line: a value with a space in it must
be quoted, and the server refuses to start on an unquoted one (it is almost always a
description left on the setting's line). A `BRIDGE_KEY` shorter than 16 characters or
with a space in it is refused too.

On start-up it checks everything and says what it found:

```
[18:10:02] ok Vobiz push bridge listening on http://localhost:8787
[18:10:03] ok Tunnel: https://example.trycloudflare.com reaches this server
[18:10:04] ok Vobiz: application Vobiz_Flutter_Push_Bridge now answers at https://example.trycloudflare.com/answer
[18:10:04] ok Vobiz: +919876543210 now rings this bridge
[18:10:04] ok Webhooks: Vobiz signatures (V3/V2) and nonces are checked
[18:10:04] .. Calls to +919876543210 ring alice
[18:10:04] .. Inbound calls ring for 45 s
[18:10:04] !! Access tokens: /token mints a token for any sub to anyone with the bridge key. Set JWT_ALLOWED_SUBS to limit it.

  Connect the app: Identity tab → Sample server, paste this line:

    https://example.trycloudflare.com#key=…
```

The line is printed once, when the bridge key is created. Later it is `bridgeKey` in
`bridge-state.json` or your `BRIDGE_KEY`.

With `VOBIZ_AUTH_ID`, `VOBIZ_AUTH_TOKEN` and `VOBIZ_NUMBER` set, the server creates
(or updates) the application `Vobiz_Flutter_Push_Bridge` with its answer and hangup
URLs and attaches the number to it. It will not take a number that another
application already has unless `FORCE_ATTACH=true`. Without those settings, create
the application yourself in the Vobiz Console with answer URL `<PUBLIC_URL>/answer`
and hangup URL `<PUBLIC_URL>/hangup` (both POST), and attach the number.

A quick tunnel gets a new address each time it starts. Put the new one in
`PUBLIC_URL`, restart the server (it re-points the application), and paste the new
line in the app.

## Who an inbound call rings: ROUTES and ALWAYS_RING

The server does not know which phones are signed in. It rings exactly what these two
settings name, and **with both empty it rings nobody** (it warns at start-up, and the
caller hears "Sorry, nobody is available").

- `ROUTES`: for each of your numbers, who to ring, separated by `;`. A name is a SIP
  user: an endpoint username, or `<sub>_<VOBIZ_AUTH_ID>` for an app signed in with an
  access token. An entry of `+` and digits (E.164) is a phone number, rung with
  `<Number>` in the same Dial:
  `ROUTES=+919876543210=alice;+918000000000=bob,carol,+919812345678`.
- `ALWAYS_RING`: SIP users rung for every inbound call, whatever number was dialled
  (a browser, for example), comma separated.

Every name listed rings, signed in or not: a user with no registration just fails
its own leg. The PSTN legs show the dialled Vobiz number as caller ID
(`CALLER_ID_MODE=number`, the default); with `CALLER_ID_MODE=caller` no `callerId` is
sent and Vobiz derives it from the caller, which the carrier may refuse for an
outbound leg. PSTN legs are billed as outbound calls.

`RING_SECONDS` (default 45) is how long the Dial rings. Keep it at 35 or more: Vobiz
holds a closed app's leg for up to 30 seconds while its push wakes the phone, and a
shorter Dial gives up first.

## In the app

1. Identity tab → **Sample server**: paste the line the server printed. The app then
   uses this server for access tokens, conferences, push sign-up and, if you switch it
   on, the connection watch.
2. **Incoming calls** (Vobiz push): sign in with **Remember me** ticked, allow
   notifications (and full-screen notifications, if Android asks). With a sample
   server set, the app signs the phone up for Vobiz push through it.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8787` | Port to listen on |
| `PUBLIC_URL` | — | This server's public HTTPS address (from the tunnel) |
| `VOBIZ_AUTH_ID`, `VOBIZ_AUTH_TOKEN` | — | Your account: webhook signatures, access tokens, conferences, push sign-up, linking the number |
| `VOBIZ_NUMBER` | — | The number to point at this server, in E.164 (a missing `+` is added) |
| `VOBIZ_APP_NAME` | `Vobiz_Flutter_Push_Bridge` | Name of the application it finds or creates |
| `FORCE_ATTACH` | `false` | Move the number here even if another application has it |
| `ROUTES` | — | Who each number rings: `+91…=alice,bob,+9198…;+91…=carol`. See above |
| `ALWAYS_RING` | — | SIP users rung for every inbound call, comma separated |
| `RING_SECONDS` | `45` | How long the one Dial rings (its `timeout`). Clamped to 15–120; keep it at 35 or more |
| `CALLER_ID_MODE` | `number` | `number`: the app's SIP call shows your Vobiz number, as the web Playground does. `caller`: pass the real caller through |
| `SIP_HEADER_STYLE` | `suffix` | How the call reference is written in `<User sipHeaders>`; Vobiz's docs show both `RefX-VH=` and `Ref=` |
| `JWT_SUB` | `flutter-app` | Access tokens: the user id (`sub`) `POST /token` mints for when the app sends none. The app registers as `<sub>_<VOBIZ_AUTH_ID>` |
| `JWT_ALLOWED_SUBS` | — | Access tokens: the other subs `/token` may mint, comma separated; any other is refused (403). Empty: any sub |
| `JWT_TTL_SECONDS` | `3600` | Access tokens: lifetime, clamped to 180–86400 (the platform's limits). It counts from the token's start time, which is set a minute in the past (so a registrar whose clock is behind accepts it): a new token has this many seconds less one minute left. The SDK renews 60 s before expiry |
| `JWT_APP_ID` | — | Access tokens: the application whose Answer URL handles the app's outbound calls (the `app` claim). Without it, the account's default application, and the registrar may refuse the token (10001). This server's own application only rings phones, so point this at the one your outbound calls use (the Playground application, for example) |
| `LOST_BEEP_SECONDS` | `3` | Connection watch: seconds without an "alive" report from the app before the other party hears the connection-lost beep. Clamped to 2–10 |
| `LOST_HANGUP_SECONDS` | `15` | Connection watch: seconds without a report before the server ends the call (the SDK gives up at 12 s, but an offline phone's hangup cannot reach Vobiz). Clamped to 5–300; `0` never ends it |
| `CONF_HOST_LOST_SECONDS` | `2` | Connection watch, conferences: seconds without a report from the host app before the server ends the whole room, as a phone call ends when one side drops. A Wi-Fi ↔ mobile data switch can take about 2 s, and may end the room. Clamped to 1–300 |
| `BRIDGE_KEY` | generated | The key the app sends (`X-Bridge-Key`): at least 16 characters, no spaces. Saved in `bridge-state.json` when generated |
| `VOBIZ_API_URL` | `https://api.vobiz.ai` | The Vobiz API address. Change it only to test against another server |
| `ALLOW_UNSIGNED_WEBHOOKS` | `false` | `true` accepts webhooks without a Vobiz signature. Local tests only |

## Routes

| Route | Called by | Purpose |
|---|---|---|
| `POST /answer` | Vobiz | An inbound call: the one Dial, at once |
| `POST /dial-result/<call>.<tag>` | Vobiz | The Dial ended: hang up (answered, missed, caller hung up), or the busy tone when everyone rung is on a call this server connected. Never dials again |
| `POST /dial-events/<call>.<tag>` | Vobiz | Live events for the Dial's legs. Only an answer event counts as answered (Vobiz can report `DialStatus=completed` for a ring nobody picked up); it also says which SIP user answered |
| `POST /hangup` | Vobiz | The caller's leg ended |
| `POST /token` | the app | An access token (JWT), see below |
| `POST /push/devices/register` | the app | Sign this phone up for Vobiz push, see below |
| `DELETE /push/devices/logout` | the app | Stop Vobiz pushing to this phone |
| `POST /call/alive`, `/call/ended` | the app | Connection watch, see below |
| `POST /conference/add`, `/state`, `/participant`, `/end` | the app | Conference, see below |
| `POST /conf-room/<room>.<role>.<tag>` | Vobiz | A leg's XML: the room (host, guest, a dialled person, or a resume) |
| `POST /conf-hold/<room>.hold.<tag>` | Vobiz | A person on hold: looped hold music |
| `POST /conf-events/<room>.events.<tag>` | Vobiz | Someone entered or left the room |
| `POST /conf-dial/<room>.dial.<tag>` | Vobiz | A call dialled into the room ended (its `hangup_url`) |
| `POST /dtmf-test`, `/dtmf-test-digits` | Vobiz | DTMF test, see below |
| `GET /busy.wav` | Vobiz | Three seconds of busy tone |
| `GET /lost.wav` | Vobiz | The connection-lost beep: 0.25 s of 1 kHz in 2.5 s, played looped |
| `GET /hold.wav` | Vobiz | Eight seconds of quiet hold music, played looped |
| `GET /health` | anyone | `{"ok": true, "service": "vobiz-push-bridge", "instance": "<random>"}` |

Every Vobiz route needs a valid signature. `<call>.<tag>` is the Vobiz CallUUID and an
HMAC the server made (the same for rooms and roles), so the signed URL (Vobiz signs the
URL, not the body or query string) names the call. A request target that is not a URL
is answered 400.

## Access tokens

The example's **Access token** tab signs in with a short-lived JWT instead of an
endpoint password. With its token server left empty it asks this server:

1. `POST /token` (bridge key) mints `{"iss": VOBIZ_AUTH_ID, "sub": <user id or
   JWT_SUB>, "nbf", "exp", "per": {"voice": {"incoming_allow": true,
   "outgoing_allow": true}}, "app": JWT_APP_ID}` through the Vobiz API. The Auth Token
   never leaves the server. `nbf` is a minute in the past, because the registrar
   refuses a token whose `nbf` its clock has not reached (10005); `sub` is letters,
   digits, `_` or `-`, at most 50. Set `JWT_APP_ID`: a token without `app` can be
   refused with 10001 (the server warns once).
2. The SDK registers as `<sub>_<VOBIZ_AUTH_ID>` with the token in `X-Vobiz-Jwt`, and asks
   for the next token a minute before this one expires.
3. To ring that identity, list `<sub>_<VOBIZ_AUTH_ID>` in `ROUTES` or `ALWAYS_RING`;
   it is rung as `<User>sip:<sub>_<VOBIZ_AUTH_ID>@registrar.vobiz.ai</User>`.

Outbound calls go to the token's `app`: set `JWT_APP_ID` to the application whose Answer
URL dials out for you.

**Anyone with the bridge key can mint a token for any `sub`** and so sign in as that
user, take their calls and place calls as them, unless `JWT_ALLOWED_SUBS` limits the
subs. In production, issue tokens only after your own user has signed in, with that
user's id as `sub`.

## Vobiz push sign-up

Vobiz pushes a held call only to the phones signed up for the called SIP user, and its
device API takes the account's Auth ID and Auth Token. The app signs up through this
server instead, with the SDK's `VobizPushDevices` pointed at it:

```dart
VobizPushDevices(
  baseUrl: Uri.parse(serverUrl),
  pathPrefix: '/push/devices',
  authHeaders: () => {'X-Bridge-Key': key, 'X-Bridge-User': client.sipUsername!},
)
```

- `POST /push/devices/register` takes exactly the body `VobizPushDevices.register`
  sends (`device_id`, `push_token`, `platform`, `push_type`, `app_bundle_id`,
  `app_version`, `sdk_version`, `sip_username`). It needs `X-Bridge-Key` and
  `X-Bridge-User`. The server refuses (403) a `sip_username` other than
  `X-Bridge-User`, and one that is neither an endpoint of its account nor
  `<sub>_<VOBIZ_AUTH_ID>`. It sets `auth_id` to its own account's Auth ID, sends the
  request to `<VOBIZ_API_URL>/api/v1/devices/register` with its own `X-Auth-ID` and
  `X-Auth-Token`, and relays Vobiz's status and JSON reply.
- `DELETE /push/devices/logout` takes `{device_id}` and forwards it to
  `/api/v1/devices/logout` the same way. It needs the key; `X-Bridge-User` is optional
  (a phone that has just signed out may have none to send).
- Other answers: 400 a body or `X-Bridge-User` the server cannot use, 401 no or wrong
  key (or, for register, no `X-Bridge-User`), 502 Vobiz could not be reached, 503 the
  account is not set or its endpoints could not be listed.
- The reply never carries the Auth Token, the bridge key or a push token, and no log
  line does.

## Connection watch

A phone that loses its network cannot tell anyone, and the other party just hears
silence. So during a call the app can report `POST /call/alive` every second. When the
reports stop for `LOST_BEEP_SECONDS`, the server (still online) has Vobiz play
`/lost.wav` to the other party, looped, so they hear a beep every 2.5 s. The beep
stops when the app reports again (the SDK restarts ICE once the network is back).

The SDK ends a call that is not back within 12 s, but the BYE cannot leave an offline
phone, and Vobiz then keeps the call up, and billed, for about five minutes (tested:
its WebRTC server ends it 300 s after the last audio, recorded as a normal hangup).
So after `LOST_HANGUP_SECONDS` without a report the server ends the call itself.

The app reports only while its switch for the watch is on (off by default), a sample
server is set and it is signed in, because the server can then end a call whose app
stops reporting. It stops reporting for a call the server refuses (401, 403, 404).

Which calls it covers, by the `call_uuid` the app reports:

- calls the app placed: its own CallUUID; the beep goes to the callee;
- inbound calls this server rang: the `PushRef` SIP header of the INVITE (the caller's
  CallUUID); the beep goes to the caller. For a call Vobiz held while its push woke
  the phone, this needs the INVITE to keep the `<User sipHeaders>` values, which has
  not been checked live yet;
- not inbound calls that did not come through this server's `/answer`.

The first report of a call is checked: the server acts only on a call of the SIP user
in `X-Bridge-User`. For an inbound call that is the user who answered it, once Vobiz
has said who did; until then, any user it rang.

## DTMF test

The SDK sends keypad presses as RFC 4733 telephone-events when the call negotiated
them, otherwise as SIP INFO; a phone on the other end does not hear either as tones. To check that they reach Vobiz, call the app through the
Vobiz API with this server as the answer URL, answer, and press four digits:

```bash
curl -X POST "https://api.vobiz.ai/api/v1/Account/$VOBIZ_AUTH_ID/Call/" \
  -H "X-Auth-ID: $VOBIZ_AUTH_ID" -H "X-Auth-Token: $VOBIZ_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"from": "<your Vobiz number, no +>", "to": "sip:<endpoint>@registrar.vobiz.ai",
       "answer_url": "'"$PUBLIC_URL"'/dtmf-test", "answer_method": "POST"}'
```

The server logs `Vobiz received "1234"` and reads the digits back to the caller.
`<PUBLIC_URL>/dtmf-test` also works as the answer URL of the app's own test call.

## Conference

The app's **Add** button (the SDK's `VobizConference`) asks the server to make the call
a conference. Vobiz mixes conferences in rooms (`<Conference>`); the server does the
REST calls, since they need the Auth Token:

1. **The first add** moves both sides of the app's call into a new room
   `vc-<call>-<random>` with the Transfer API (`legs=both`): the app's leg as the host
   (`endConferenceOnExit="true"`), the other side as a guest. The phone's own SIP call
   is not touched, so its audio carries on through the room. Two adds at once for one
   call share one room.
2. **Each add** dials the person (`POST /Call/`, `from` = the app's caller ID or
   `VOBIZ_NUMBER`); when they answer, Vobiz asks `/conf-room/…` for their XML, which is
   the same room.
3. **Who is in the room** comes from the room's enter and exit callbacks
   (`/conf-events/…`) and the dialled calls' `hangup_url` (`/conf-dial/…`): Vobiz's read
   API does not list a live room's members.
4. **Mute and unmute** use the member API. **Hold** transfers the person's leg out of
   the room onto `/hold.wav` (looped `<Play loop="0">`); **resume** transfers it back,
   as a new member (muted again if they were). **Remove** hangs up their leg.
5. **The room ends** when the app's leg leaves (Vobiz kicks everyone), when the app asks
   (`/conference/end`), when nobody but the app is left (in the room, ringing or on
   hold), or `CONF_HOST_LOST_SECONDS` (2 s) after the app's phone stops reporting
   (the connection watch): like a phone call, the call ends for everyone when its
   host drops. People on hold and calls still ringing are hung up too.

Every leg joins with `stayAlone="true"`: Vobiz otherwise drops a member who is alone in
the room, even for the moment both sides of the call are moving in. A conference holds
at most 20 people (the account's `max_conf_members`). The connection-lost beep is not
played in a conference: the call's legs are no longer bridged to each other.

| Request | Auth | Body | Response |
|---|---|---|---|
| `/conference/add` | `X-Bridge-Key`, and `X-Bridge-User` | `{call_uuid, number \| user, caller_id?}` (with the key alone also `host_leg`: `aleg` or `bleg`) | the state; 400 bad input, 403 not this SIP user's live call, 409 room full, 502 Vobiz refused |
| `/conference/state` | same | `{call_uuid}` | the state; 404 not a conference |
| `/conference/participant` | same | `{call_uuid, participant_id, action}`, `action` = `mute`, `unmute`, `hold`, `resume`, `remove` | the state; 409 not possible now (e.g. not in the room) |
| `/conference/end` | same | `{call_uuid}` | the state, `active: false` |

The state: `{room, active, ended_reason?, participants: [{id, label, you, role, status,
muted, reason?}]}` with `role` `host` (the app), `guest`, `added` or `other`, and
`status` `connecting`, `dialing`, `joined`, `on_hold`, `left` or `failed`. `call_uuid` is
the id the app reports to `/call/alive`: its own CallUUID for a call it placed, the
`PushRef` for a call this server rang. With `X-Bridge-User` a request acts only on that
SIP user's calls (for an inbound call, the user who answered); with the key alone it
may act on any live call of the account, and a room it opens on an inbound call is the
answering user's.

## App ↔ server protocol

Every app request is JSON and carries:

- `X-Bridge-Key: <bridge key>`: the `key=` part of the line the server printed;
- `X-Bridge-User: <SIP user>`: the SIP user the app is signed in as (for an access
  token, `<sub>_<VOBIZ_AUTH_ID>`). The app sends it only when it is signed in, and
  leaves it out otherwise. Without it a request is the key holder's; a header that is
  present but empty or not a user name is answered 400.

| Request | `X-Bridge-User` | Body | Response |
|---|---|---|---|
| `POST /token` | optional | `{reason?, sub?}` (`sub` also as `?sub=`) | `{token, sub, exp, sip_username}`; 400 bad `sub`, 401 bad key, 403 `sub` not allowed, 502 Vobiz refused |
| `POST /push/devices/register` | required, = `sip_username` | the SDK's device body | Vobiz's reply (see Vobiz push sign-up) |
| `DELETE /push/devices/logout` | optional | `{device_id}` | Vobiz's reply |
| `POST /call/alive` | required | `{call_uuid}` | `{ok}`; 401 no key or no `X-Bridge-User`, 403 not this SIP user's live call |
| `POST /call/ended` | required | `{call_uuid}` | `{ok}` |
| `POST /conference/*` | optional | see Conference | see Conference |

The `<Dial>` puts two SIP headers on every `<User>`: `PushRef`, this call's CallUUID
(the caller's leg), which the app sends back as `call_uuid` to `/conference/*` and
`/call/alive`; and `Caller`, the real caller's number, left out when the caller is not
a phone number (a SIP user such as a PBX extension). They are written `PushRefX-VH=`
and `CallerX-VH=`, or `PushRef=` and `Caller=` with `SIP_HEADER_STYLE=plain`.

## Security

This is a sample, and its authentication is sample-grade:

- **One shared key for every app.** The bridge key travels on every app request. Anyone
  who has it can mint a token for any `sub` (unless `JWT_ALLOWED_SUBS` limits them),
  manage the conference of any live call of the account, and sign a phone up for push
  as any SIP user of the account. Treat it like a password, use the tunnel's HTTPS
  address only, and change `BRIDGE_KEY` (then paste the new line) to cut every phone
  off.
- **`X-Bridge-User` is what the app says it is, not proof.** It picks the app's leg of
  a call and keeps one app from acting on another user's call by mistake; it does not
  stop a key holder who claims to be someone else.
- **What a production backend does instead:** sign each person in with your own user
  accounts, give each session its own credential, mint tokens only for that person's
  own id, and sign a phone up for push only for that person's own SIP user.
- Webhooks fail closed: every Vobiz request needs a valid V3 (or V2) signature over
  `PUBLIC_URL` + path. Each nonce and each signature is accepted once (remembered for
  24 hours, at most 10000 of them, across restarts). Vobiz nonces are random and
  nothing is timestamped, so there is no clock-based freshness check. Vobiz signs only
  callback URLs that have credentials configured; if your log shows "no
  X-Vobiz-Signature headers", set them on the application.
- The Auth Token never leaves the server: not in a reply, not in a log line, and the
  push sign-up never returns it, the bridge key or a push token.
- `bridge-state.json` (bridge key, webhook secret, seen nonces) is written `0600` on
  Linux and macOS, so only your user can read it. Windows does not apply that mode:
  there the folder's permissions protect it. `.env`, `bridge-state.json` and key files
  are git-ignored. Do not commit them.

## Limits

- Android only. iOS needs PushKit and an APNs VoIP certificate, which this example
  does not set up.
- A closed phone rings only while its last registration lasts (the SDK asks for an
  hour) and only if it is signed up for Vobiz push. Closed longer, or signed out: its
  leg fails at once; the other targets still ring.
- Decline stops only the phone that declined; the others keep ringing. The caller
  hears the busy tone only when everyone rung is on a call this server connected;
  Vobiz also reports "busy" for a SIP user it could not reach, so any other busy ends
  with "Sorry, there was no answer".
- `<Hangup reason="busy">` rejects a call unbilled only while it is unanswered. Whether
  the caller's leg is already answered (and billed) once the `<Dial>` has run has not
  been checked on a CDR yet; the caller hears a busy tone either way.
- Calls in progress live in memory: restarting the server mid-call drops them. An
  answered call is kept until it ends (five hours at most), others for ten minutes.
- Swiping the app from Recents is fine; **Force stop** (Settings → Apps) is not:
  Android delivers no push to a force-stopped app until it is opened again.
- Some Android makers stop pushes to apps swiped from Recents unless the app may run
  in the background (battery optimisation, "autostart"). Pixel and the emulator do not.
