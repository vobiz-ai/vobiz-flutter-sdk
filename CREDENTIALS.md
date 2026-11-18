# Credentials: production sign-in, and the demo modes

> **The account Auth ID and Auth Token never belong on a device.** The Auth Token is
> the account's full REST credential: it buys numbers, places calls and reads call
> records. A production app signs each user in as **their own SIP endpoint**, with
> credentials that **your backend** creates and hands out. Zero-Config Setup, which
> sends the Auth Token from the device, is a demo and is off unless you set
> `SdkConfig(unsafeDemoZeroConfig: true)`.

Nothing is compiled into the SDK or the example app.

## Production: one endpoint per user, issued by your backend

```
 App (your user is signed in to YOUR service)
   │  POST /voice/sip-credentials   Authorization: <your own session token>
   ▼
 Your backend  ── holds the Vobiz Auth ID + Auth Token, server-side only
   │  first time for this user: POST /api/v1/Account/{auth_id}/Endpoint/
   │  stores endpoint_id, username and the password it generated
   ▼
 App  ◄── {"sip_username": "...", "sip_password": "..."}
   │
   └─ registers with registrar.vobiz.ai as that endpoint
```

Rules that keep devices from logging each other out:

- **One endpoint per user** (agent). Never share one endpoint between users. If one
  user can be signed in on several devices at once, give each device its own
  endpoint.
- **Create once, reuse.** Vobiz never returns an endpoint's password after creation
  ("write-only"), so your backend stores the password it generated (encrypted) and
  returns the same one on every sign-in and every app wake.
- **Never rotate on sign-in.** Rotate only on purpose (suspected leak, user removed),
  with `POST .../Endpoint/{endpoint_id}/` and a new `password`. A rotated device gets
  `403` at its next REGISTER; the SDK then asks your backend again (see below).
- **Delete** the endpoint when the user is removed
  (`DELETE .../Endpoint/{endpoint_id}/`): it unregisters every device at once.

### In the app

```dart
final client = VobizClient();

final provider = VobizBackendCredentialsProvider(
  url: Uri.parse('https://api.example.com/voice/sip-credentials'),
  headers: () async => {'Authorization': 'Bearer ${await mySession.accessToken()}'},
);

final session = await client.connectWithCredentialsProvider(provider.call);
session.failures.listen((e) => showSignInProblem(e.message));
// When your user signs out:
await client.disconnect();
await session.dispose();
```

Or write the provider yourself, for example to answer from a secure-storage cache:

```dart
final session = await client.connectWithCredentialsProvider((request) async {
  if (request == VobizCredentialsRequest.signIn) {
    final cached = await cache.read();
    if (cached != null) return cached;            // no network on a push wake
  }
  final fresh = await myApi.sipCredentials(reason: request.name);
  await cache.write(fresh);
  return fresh;                                   // CredentialConfig
});
```

The provider is asked:

| `VobizCredentialsRequest` | When | What to return |
|---|---|---|
| `signIn` | `connectWithCredentialsProvider` | cached credentials if you have them |
| `rejected` | the registrar refused the last ones (401/403) | fresh ones from your backend |
| `refresh` | you called `session.refresh()` | fresh ones from your backend |

After `maxRefreshes` (default 1) refusals in a row the session stops and reports a
`VobizRegistrationException` on `session.failures`. A provider that throws fails with
`VobizCredentialsException`.

### Reference backend (Node 18+, Express)

The Vobiz calls below are the documented
[Create an Endpoint](https://docs.vobiz.ai/endpoint/create-endpoint) request. Replace
the in-memory `store` with your database, and `requireUser` with your own
authentication.

```js
import crypto from 'node:crypto';
import express from 'express';

const VOBIZ = 'https://api.vobiz.ai/api/v1';
const AUTH_ID = process.env.VOBIZ_AUTH_ID;        // server-side only
const AUTH_TOKEN = process.env.VOBIZ_AUTH_TOKEN;  // server-side only
const APP_ID = Number(process.env.VOBIZ_APP_ID);  // the application whose answer URL routes these calls

const store = new Map(); // userId -> { endpointId, username, password }  (use your DB, encrypt password)

async function vobiz(method, path, body) {
  const res = await fetch(`${VOBIZ}/Account/${AUTH_ID}${path}`, {
    method,
    headers: { 'X-Auth-ID': AUTH_ID, 'X-Auth-Token': AUTH_TOKEN, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Vobiz ${method} ${path}: HTTP ${res.status} ${await res.text()}`);
  return res.status === 202 || res.status === 204 ? {} : res.json();
}

async function endpointFor(user) {
  const existing = store.get(user.id);
  if (existing) return existing;                              // never rotate on sign-in
  // username: alphanumeric only, unique per account, immutable.
  const username = `u${crypto.createHash('sha256').update(user.id).digest('hex').slice(0, 20)}`;
  const password = crypto.randomBytes(24).toString('base64url'); // Vobiz never returns it: keep it
  const created = await vobiz('POST', '/Endpoint/', {
    username,
    password,
    alias: `agent-${username}`,     // letters, digits, - and _ only
    application: APP_ID,
  });
  const record = { endpointId: created.endpoint_id, username, password };
  store.set(user.id, record);
  return record;
}

// requireUser: your own authentication middleware; it sets req.user.
const app = express();
app.use(express.json());

app.post('/voice/sip-credentials', requireUser, async (req, res) => {
  try {
    const ep = await endpointFor(req.user);
    res.json({ sip_username: ep.username, sip_password: ep.password, display_name: req.user.name });
  } catch (e) {
    console.error(e);
    res.status(502).json({ error: 'Could not issue SIP credentials' });
  }
});
```

A `409` from Create means the username already exists on the account (for example the
store was lost): look it up with
[List all endpoints](https://docs.vobiz.ai/endpoint/list-all-endpoints)
(`?username__exact=`), set a new password with
[Update an Endpoint](https://docs.vobiz.ai/endpoint/update-endpoint), and store that.

### Access tokens (JWT)

Instead of an endpoint password, the app can sign in with a short-lived access token
that your backend mints. Nothing long-lived reaches the device, no endpoint has to exist
in the Console, and each of your users gets their own SIP identity, `<sub>_<auth_id>`.
This is what the web SDK's `loginWithAccessTokenGenerator` does (see the Vobiz WebRTC
demo, vobiz-ai/Vobiz-RTC-demo).

**1. Your backend mints the token** after authenticating your app's user with its own
session. The Vobiz API signs it with the account Auth Token:

```js
// POST /voice/token  (your route; your own auth middleware first)
app.post('/voice/token', requireUser, async (req, res) => {
  const nbf = Math.floor(Date.now() / 1000) - 60; // a minute back: see below
  const claims = {
    iss: process.env.VOBIZ_AUTH_ID,
    sub: req.user.id,                       // A-Z a-z 0-9 _ -, at most 50; registers as <sub>_<auth_id>
    nbf,
    exp: nbf + 3600,                        // exp - nbf: 180 s to 24 h
    app: process.env.VOBIZ_APP_ID,          // whose Answer URL handles outbound calls
    per: { voice: { incoming_allow: true, outgoing_allow: true } },
  };
  const r = await fetch(`https://api.vobiz.ai/api/v1/Account/${process.env.VOBIZ_AUTH_ID}/JWT/Token/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Auth-ID': process.env.VOBIZ_AUTH_ID,
      'X-Auth-Token': process.env.VOBIZ_AUTH_TOKEN,
    },
    body: JSON.stringify(claims),
  });
  if (!r.ok) return res.status(502).json({ error: 'token not minted' });
  res.json({ token: (await r.json()).token });
});
```

Two things we saw on the live platform (2026-10-25):

- **Put `app` in the token.** A token without it is handled by the account's default
  application, and where that cannot be used the registrar refuses the token with
  10001 `INVALID_ACCESS_TOKEN`.
- **Set `nbf` a minute in the past.** The registrar refuses a token whose `nbf` it has
  not reached yet (10005 `ACCESS_TOKEN_NOT_VALID_YET`), and its clock can be a second
  behind your server's. (The provider session copes with that by presenting the same
  token again 3 s later, but backdating avoids it.)

**2. The app signs in with it** and the SDK keeps it fresh:

```dart
final provider = VobizBackendAccessTokenProvider(
  url: Uri.parse('https://api.example.com/voice/token'),
  headers: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
);
final session = await client.connectWithAccessTokenProvider(provider.call);
// client.sipUsername == '<sub>_<auth_id>'; 60 s before exp the provider is asked
// again (reason "expiring") and the client re-registers without touching a call.
```

**3. Calls.** Outbound INVITEs carry the token; the registrar tells the media server
the account and the token's `app`, whose Answer URL gets the call (without `app`, the
account's default application). To ring the user, answer an inbound call with
`<Dial><User>sip:<sub>_<auth_id>@registrar.vobiz.ai</User></Dial>`.

- `per.voice.outgoing_allow` must be true for `makeCall`: otherwise it throws before
  dialling. The SDK does not check `incoming_allow`; the platform does.
- A refused token (expired, wrong signature…) fails the registration with the
  registrar's reason, 10001 to 10010 (`VobizAccessTokenException.tokenErrorName`, for
  example `ACCESS_TOKEN_EXPIRED`), and the provider is asked again with `rejected`.
- Revoking: stop issuing tokens to that user; the current one dies at `exp`.
- `TokenConfig` is not token authentication (its token is sent as a SIP password) and
  is deprecated.

### Transfers and recordings in production

`transferCall` and the Playground recordings list are demo features (they post the
account Auth Token, or read a list shared by everyone on the demo server). In
production, make the transfer from your backend with the Vobiz API and the call's
`client.callUuid`, and serve recordings from your backend, scoped to the signed-in user.

### Receiving calls in production

Attach your number to an application whose answer URL is on your backend, and have it
answer with a `<Dial>` to the right user's endpoint (`<User>sip:USERNAME@registrar.vobiz.ai</User>`).
Your backend knows which user should ring, so no shared in-memory state is involved.

## Demo: Zero-Config Setup (Auth ID and Auth Token)

For trying the SDK on your own account in the example app, the same way as the web
Playground. **Not for production builds.**

```dart
final client = VobizClient(
  config: const SdkConfig(unsafeDemoZeroConfig: true), // DEMO ONLY
);
await client.connectWithAuthToken(authId: authId, authToken: authToken);
```

Without the flag, `connectWithAuthToken`, `transferCall` and reading the shared demo
server's recordings throw `VobizDemoModeRequiredException` and send nothing.

1. Sign in to the Vobiz Console.
2. Copy the **Auth ID** (it looks like `MA_XXXXXXXX`) and the **Auth Token** from the
   dashboard. The Auth Token is not your login password.
3. Enter both on the Zero-Config Setup tab, or pass them to `connectWithAuthToken`.

The webhook server then finds or creates two things on your account and the SDK signs
in as the endpoint:

| Created on your account | Name |
|---|---|
| Application, answer URL `<webhook>/api/answer` | `Vobiz WebRTC Playground` |
| SIP endpoint attached to it, **with a new password each sign-in** | alias `Vobiz WebRTC Playground Endpoint`, username `play…` |

Known limits, all of which the production path avoids:

- There is **one** such endpoint per account, and every sign-in rotates its password,
  so a second phone, the web Playground or a push wake on the same account logs the
  others out at their next REGISTER.
- The Auth Token travels to the webhook server on sign-in and on every transfer.
- The hosted server's recordings list is shared by everyone who uses it.
- The hosted server keeps "which endpoint to ring" in memory; after it restarts, sign
  in with Zero-Config again before expecting incoming calls.

## SIP Direct: an endpoint you already have

1. In the Vobiz Console, open **Voice → Endpoints** and create (or pick) an endpoint.
2. Attach it to an application whose answer URL decides what calls do.
3. Save the password when you create the endpoint: it is shown once.
4. Pass the username and password in a `CredentialConfig` to
   `connectWithCredentials`, or enter them on the example's SIP Direct tab.

SIP Direct sends no account credentials anywhere. It is what the credentials provider
does under the hood, without the refresh.

## Caller ID

Calls to phones need a caller ID the account owns: a number bought from Vobiz
(**Voice → Numbers**) or your trial number, in E.164 form such as `+918000000000`.
A number the account does not own fails at once, with no B leg.

## Keep them out of source control

Never commit an Auth Token, an endpoint password or a real number. If an Auth Token
has been committed or shared, rotate it in the Vobiz Console: removing it from the
files does not remove it from git history.

The live sign-in test (`example/integration_test`) takes its credentials from
`--dart-define-from-file`, never from the code. See [example/README.md](example/README.md).
