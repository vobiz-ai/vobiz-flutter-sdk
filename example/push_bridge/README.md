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
             ┌────────────────────────────────┴───────────────────────────┐
             │ 1. Firebase push (high priority) ──> phone shows the call   │
             │ 2. <Dial><User>sip:your-endpoint</User></Dial> right away   │
             │      app open: it rings at once                             │
             │      app closed: the endpoint is offline, the dial fails,   │
             │      and the caller hears ringback while the bridge dials   │
             │      again every 3 seconds                                  │
             └─────────────────────────────────────────────────────────────┘
user taps Accept ──> app opens, signs in with the saved credentials ──> the next
dial reaches it ──> the app answers by itself
user taps Decline ──> app tells the bridge ──> the caller hears busy
caller hangs up ──> Vobiz calls /hangup ──> a push stops the phone ringing
```

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
```

On start-up it checks everything and says what it found:

```
[18:10:02] ok Vobiz push bridge listening on http://localhost:8787
[18:10:03] ok Firebase: service account for project my-project works
[18:10:03] ok Tunnel: https://example.trycloudflare.com reaches this server
[18:10:04] ok Vobiz: application Vobiz_Flutter_Push_Bridge now answers at https://example.trycloudflare.com/answer
[18:10:04] ok Vobiz: +919876543210 now rings this bridge
[18:10:04] ok Webhooks: Vobiz signatures are checked
[18:10:04] .. Apps registered: none yet

  In the app: Identity tab → Incoming calls → Push server, paste this line:

    https://example.trycloudflare.com#key=…
```

With `VOBIZ_AUTH_ID`, `VOBIZ_AUTH_TOKEN` and `VOBIZ_NUMBER` set, the bridge creates
(or updates) the application `Vobiz_Flutter_Push_Bridge` with its answer and hangup
URLs and attaches the number to it. It will not take a number that another
application already has unless `FORCE_ATTACH=true`. Without those settings, create
the application yourself in the Vobiz Console with answer URL `<PUBLIC_URL>/answer`
and hangup URL `<PUBLIC_URL>/hangup` (both POST), and attach the number.

A quick tunnel gets a new address each time it starts. Put the new one in
`PUBLIC_URL`, restart the bridge (it re-points the application), and paste the new
line it prints into the app.

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
| `RING_SECONDS` | `45` | How long a caller waits for the app |
| `CALLER_ID_MODE` | `number` | `number`: the app's SIP call shows your Vobiz number, as the web Playground does. `caller`: pass the real caller through |
| `SIP_HEADER_STYLE` | `suffix` | How the call reference is written in `<User sipHeaders>`; Vobiz's docs show both `RefX-VH=` and `Ref=` |
| `VERIFY_SIGNATURES` | `true` | Reject webhooks without a valid `X-Vobiz-Signature-V3` (needs the Auth Token) |
| `ALWAYS_RING` | — | Endpoints to ring even if no app registered, comma separated |
| `BRIDGE_KEY` | generated | The key the app sends; saved in `bridge-state.json` |

Whatever the caller ID mode, the push shows the real caller, and the bridge passes
the real caller to the app in a SIP header as well.

## Routes

| Route | Called by | Purpose |
|---|---|---|
| `POST /answer` | Vobiz | An inbound call: push, then dial the endpoint |
| `POST /dial-result` | Vobiz | One dial attempt ended: dial again, or hang up |
| `POST /hangup` | Vobiz | The caller's leg ended: stop the phone ringing |
| `GET /ringback.wav` | Vobiz | Three seconds of ringback, played between attempts |
| `POST /push/register`, `/push/unregister` | the app | Ring this endpoint on this device (needs the bridge key) |
| `POST /push/test` | the app | A pretend call (needs the bridge key) |
| `POST /push/accept`, `/push/decline` | the app | The user's answer (needs that call's key from the push) |
| `GET /health` | anyone | `{"ok": true}` |

## Security

- The app needs the bridge key to register; accept and decline need a per-call key
  that only the pushed phone receives.
- With `VOBIZ_AUTH_TOKEN` set, every webhook must carry a valid Vobiz signature.
- `.env`, `bridge-state.json` and service account keys are git-ignored. Do not commit
  them.

## Limits

- Android only. iOS needs PushKit and an APNs VoIP certificate, which this example
  does not set up.
- Every endpoint that has registered rings for every inbound call to the number.
- Calls in progress live in memory: restarting the bridge mid-call drops them.
- Swiping the app from Recents is fine; **Force stop** (Settings → Apps) is not:
  Android delivers no push to a force-stopped app until it is opened again.
- Some Android makers stop pushes to apps swiped from Recents unless the app may run
  in the background (battery optimisation, "autostart"). Pixel and the emulator do not.
- If Firebase's push arrives more than about 10 seconds late, Android may still have
  the app frozen when the first INVITE arrives, and that call can fail; the next
  inbound call is unaffected.
