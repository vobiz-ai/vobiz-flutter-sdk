# Credentials: production sign-in, push sign-up, and the demo modes

> **The account Auth ID and Auth Token never belong on a device.** The Auth Token is
> the account's full REST credential: it buys numbers, places calls and reads call
> records. A production app signs each user in as **their own SIP identity**, with
> credentials that **your backend** creates and hands out, and signs the phone up for
> Vobiz push **through your backend**. Zero-Config Setup, which sends the Auth Token
> from the device, is a demo and is off unless you set
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
- **Create once, reuse.** Vobiz never returns an endpoint's password after creation,
  so your backend stores the password it generated (encrypted) and returns the same one
  on every sign-in and every app wake.
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

`VobizBackendCredentialsProvider` posts `{"reason": "sign_in" | "rejected" | "refresh"}`
and reads `sip_username` and `sip_password` from the reply. Or write the provider
yourself, for example to answer from a secure-storage cache:

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
| `refresh` | you called `session.refresh()` (it ends a call in progress) | fresh ones from your backend |

A refusal that comes during a call is answered once the call has ended. After
`maxRefreshes` (default 1) refusals in a row the session stops and reports a
`VobizRegistrationException` on `session.failures`. A provider that throws, or returns an
empty username or password, fails with `VobizCredentialsException`.

### Reference backend (Node 18+, Express)

The Vobiz calls below are the
[Create an Endpoint](https://docs.vobiz.ai/endpoint/create-endpoint) request. Replace
the in-memory `store` with your database, and `requireUser` with your own
authentication.

```js
import crypto from 'node:crypto';
import express from 'express';

const VOBIZ = 'https://api.vobiz.ai/api/v1';
const AUTH_ID = process.env.VOBIZ_AUTH_ID;        // server-side only
const AUTH_TOKEN = process.env.VOBIZ_AUTH_TOKEN;  // server-side only
// The application whose answer URL routes these endpoints' calls. Application ids
// have 17 digits: keep it a string (Number() would round it to another id).
const APP_ID = process.env.VOBIZ_APP_ID;

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
  // username: letters and digits, unique per account, cannot be changed later.
  const username = `u${crypto.createHash('sha256').update(user.id).digest('hex').slice(0, 20)}`;
  const password = crypto.randomBytes(24).toString('base64url'); // Vobiz never returns it: keep it
  const created = await vobiz('POST', '/Endpoint/', {
    username,
    password,
    alias: `agent-${username}`,     // letters, digits, - and _ only
    app_id: APP_ID,
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
    res.json({ sip_username: ep.username, sip_password: ep.password });
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
This is what the web SDK's `loginWithAccessTokenGenerator` does.

**1. Your backend mints the token** after authenticating your app's user with its own
session. The Vobiz API signs it with the account Auth Token:

```js
// POST /voice/token  (your route; your own auth middleware first)
app.post('/voice/token', requireUser, async (req, res) => {
  const nbf = Math.floor(Date.now() / 1000) - 60; // a minute back: see below
  const claims = {
    iss: AUTH_ID,
    sub: req.user.id,                       // A-Z a-z 0-9 _ -, at most 50; registers as <sub>_<auth_id>
    nbf,
    exp: nbf + 3600,                        // exp - nbf: 180 s to 24 h
    app: APP_ID,                            // whose Answer URL handles outbound calls
    per: { voice: { incoming_allow: true, outgoing_allow: true } },
  };
  const r = await fetch(`${VOBIZ}/Account/${AUTH_ID}/JWT/Token/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Auth-ID': AUTH_ID, 'X-Auth-Token': AUTH_TOKEN },
    body: JSON.stringify(claims),
  });
  if (!r.ok) return res.status(502).json({ error: 'token not minted' });
  res.json({ token: (await r.json()).token });
});
```

Two minting rules:

- **Put `app` in the token.** A token without it is handled by the account's default
  application, and where that cannot be used the registrar refuses the token with
  10001 `INVALID_ACCESS_TOKEN`.
- **Set `nbf` a minute in the past.** The registrar refuses a token whose `nbf` its
  clock has not reached yet (10005 `ACCESS_TOKEN_NOT_VALID_YET`), and its clock can be a
  little behind your server's. (The provider session copes with that by presenting the
  same token again 3 s later, but backdating avoids it.)

**2. The app signs in with it** and the SDK keeps it fresh:

```dart
final provider = VobizBackendAccessTokenProvider(
  url: Uri.parse('https://api.example.com/voice/token'),
  headers: () async => {'Authorization': 'Bearer ${await mySession.token()}'},
);
final session = await client.connectWithAccessTokenProvider(provider.call);
// client.sipUsername == '<sub>_<auth_id>'. 60 s before the token expires the provider
// is asked again (reason "expiring") and the client re-registers without touching a call.
```

If your backend cannot be reached, the session asks again after 5 s, doubling the wait
up to 60 s, and reports each failure on `session.failures`.

**3. Calls.** Outbound INVITEs carry the token, and its `app` picks the application whose
Answer URL gets the call (without `app`, the account's default application). To ring the
user, answer an inbound call with
`<Dial><User>sip:<sub>_<auth_id>@registrar.vobiz.ai</User></Dial>`.

- `per.voice.outgoing_allow` must be true for `makeCall`: otherwise it throws before
  dialling. The SDK does not check `incoming_allow`.
- A refused token (expired, wrong signature…) fails the registration with the
  registrar's reason, 10001 to 10010 (`VobizAccessTokenException.tokenErrorName`, for
  example `ACCESS_TOKEN_EXPIRED`), and the provider is asked again with `rejected`.
- Revoking: stop issuing tokens to that user; the current one dies at `exp`.
- `TokenConfig` is not token authentication (its token is sent as a SIP password) and
  is deprecated.

### Push sign-up through your backend

To ring a closed app, Vobiz pushes the phones signed up for the called SIP user (see
[README.md](README.md#receiving-calls-when-the-app-is-closed-android)). Its device API
(`POST /api/v1/devices/register`, `DELETE /api/v1/devices/logout`) takes the account's
Auth ID and Auth Token, so the app signs up through your backend, with the same session
it uses for everything else:

```dart
final devices = VobizPushDevices(
  baseUrl: Uri.parse('https://api.example.com'),
  pathPrefix: '/voice/push-devices',            // POST .../register, DELETE .../logout
  authHeaders: () async => {'Authorization': 'Bearer ${await mySession.accessToken()}'},
);
await devices.register(VobizPushDevice(
  deviceId: installId,                          // made once per install, then kept
  pushToken: firebaseToken,
  sipUsername: client.sipUsername!,
  appBundleId: 'com.example.app',
  sdkVersion: VobizClient.sdkVersion,
));
// At sign-out:
await devices.logout(installId);
```

Vobiz scopes devices to the account, not to the SIP user, so a backend that forwards
the request as it is would let one user receive another user's call pushes, caller
number included, or remove their phone. Your backend must:

1. **Take `sip_username` from the signed-in user** (their endpoint's username, or
   `<sub>_<auth_id>` for an access token), never from the request.
2. **Remove only devices that this user registered.**

Added to the reference backend above:

```js
const pushOwners = new Map(); // deviceId -> userId  (use your DB)

async function vobizDevices(method, path, body) {
  const res = await fetch(`${VOBIZ}/devices/${path}`, {
    method,
    headers: { 'X-Auth-ID': AUTH_ID, 'X-Auth-Token': AUTH_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

app.post('/voice/push-devices/register', requireUser, async (req, res) => {
  const b = req.body ?? {};
  if (!b.device_id || !b.push_token) return res.status(400).json({ error: 'device_id and push_token are required' });
  const owner = pushOwners.get(b.device_id);
  if (owner && owner !== req.user.id) return res.status(403).json({ error: 'Not your device' });
  const sipUsername = (await endpointFor(req.user)).username; // rule 1 (access tokens: `${req.user.id}_${AUTH_ID}`)
  const r = await vobizDevices('POST', 'register', {
    device_id: b.device_id, push_token: b.push_token, platform: b.platform, push_type: b.push_type,
    app_bundle_id: b.app_bundle_id, app_version: b.app_version, sdk_version: b.sdk_version,
    sip_username: sipUsername,
  });
  if (r.status < 300) pushOwners.set(b.device_id, req.user.id);
  res.status(r.status).json(r.body);
});

app.delete('/voice/push-devices/logout', requireUser, async (req, res) => {
  const deviceId = req.body?.device_id;
  if (!deviceId || pushOwners.get(deviceId) !== req.user.id) {   // rule 2
    return res.status(403).json({ error: 'Not your device' });
  }
  const r = await vobizDevices('DELETE', 'logout', { device_id: deviceId });
  if (r.status < 300) pushOwners.delete(deviceId);
  res.status(r.status).json(r.body);
});
```

`VobizPushDevices` throws `VobizException` (`push_device_failed`, with your backend's
status code) for any answer that is not 2xx, and shows the reply's `message`, `error` or
`detail`.

The example's sample server does the same at `/push/devices/register` and
`/push/devices/logout`, with sample-grade authentication: one shared key, and the SIP
user the app says it is
([example/push_bridge/README.md](example/push_bridge/README.md#vobiz-push-sign-up)).
For a test build only, `VobizPushDevices.accountHeaders(authId, authToken,
unsafeDemo: true)` signs up straight to Vobiz from the device with the account
credentials; without `unsafeDemo: true` it throws `VobizDemoModeRequiredException`.

### Transfers and recordings in production

`transferCall` is a demo feature: it posts the account Auth Token to the webhook server,
so it works only after a Zero-Config sign-in. In production, make the transfer from your
backend with the Vobiz API and the call's `client.callUuid`.

`fetchRecordings` and `waitForRecording` send a plain `GET <backendUrl>/api/recording?list=1`
with **no credentials**: a server cannot tell who is asking, so it would hand its list to
anyone who knows the address. They are for the Playground server in demo mode. Serve
recordings through your own authenticated API instead, scoped to the signed-in user.

### Receiving calls in production

Attach your number to an application whose answer URL is on your backend, and have it
answer with a `<Dial>` to the right user's SIP identity
(`<User>sip:USERNAME@registrar.vobiz.ai</User>`). Your backend knows which user should
ring. For calls to a closed app, sign the phone up for Vobiz push as above.

## Demo: Zero-Config Setup (Auth ID and Auth Token)

For trying the SDK on your own account in the example app, the same way as the web
Playground. **Not for production builds.**

```dart
final client = VobizClient(
  config: const SdkConfig(unsafeDemoZeroConfig: true), // DEMO ONLY
);
await client.connectWithAuthToken(authId: authId, authToken: authToken);
```

Without the flag, `connectWithAuthToken` throws `VobizDemoModeRequiredException` and
sends nothing; `transferCall` then has no Zero-Config sign-in to use and throws
`StateError`; and reading the shared demo server's recordings throws `VobizException`
(`recordings_failed`). With the flag, `backendUrl` must still be `https` (plain `http`
only to this device or the Android emulator's host): it receives the Auth Token.

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
  so a second phone or the web Playground signing in on the same account logs the
  others out at their next REGISTER.
- The Auth Token travels to the webhook server on sign-in and on every transfer.
- The hosted server's recordings list is shared by everyone who uses it.

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
(**Voice → Numbers**) or your trial number, in E.164 form with its plus, such as
`+918000000000` (the SDK refuses anything but a plus and 7 to 15 digits). A number the
account does not own fails at once, with no B leg.

## Keep them out of source control

Never commit an Auth Token, an endpoint password, a Firebase service-account key, a
signing key or a real number. The repository's `.gitignore` covers `.env` files, Firebase
key files, `key.properties` and keystores. If an Auth Token has been committed or shared,
rotate it in the Vobiz Console: removing it from the files does not remove it from git
history.

The live sign-in test (`example/integration_test`) takes its credentials from
`--dart-define-from-file`, never from the code. See [example/README.md](example/README.md#tests).
