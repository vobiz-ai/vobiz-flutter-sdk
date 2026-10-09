#!/usr/bin/env node
/**
 * Vobiz push bridge: rings the Flutter example app for inbound calls, also
 * when the app is in the background or has been swiped away.
 *
 * Why it is needed: the app speaks SIP over a WebSocket. When Android closes
 * the app the socket closes, and the Vobiz registrar forgets the
 * registration, so an inbound call would have nothing to ring. This server
 * answers your Vobiz number instead. For every inbound call it:
 *
 *   1. sends the phone a high-priority Firebase message. That wakes the app,
 *      which shows a full-screen incoming-call screen;
 *   2. rings the app's SIP endpoint straight away (`<Dial><User>`). If the
 *      app is open, it rings at once;
 *   3. while the endpoint is offline, keeps the caller hearing ringback and
 *      dials again every few seconds, until the app has signed back in
 *      (the user tapped Accept), the user declined, or RING_SECONDS passed.
 *
 * Node 18 or newer, no npm packages. Settings come from a .env file next to
 * this script (see .env.example) or from environment variables.
 *
 *   node push-bridge.mjs
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const USERNAME_RE = /^[A-Za-z0-9_.\-+]{1,120}$/;
loadEnvFile(path.join(HERE, '.env'));

const config = {
  port: clampInt(process.env.PORT, 8787, 1, 65535),
  publicUrl: (process.env.PUBLIC_URL || '').trim().replace(/\/+$/, ''),
  serviceAccountFile: (process.env.FIREBASE_SERVICE_ACCOUNT || '').trim(),
  vobizApi: (process.env.VOBIZ_API_URL || 'https://api.vobiz.ai').trim().replace(/\/+$/, ''),
  authId: (process.env.VOBIZ_AUTH_ID || '').trim(),
  authToken: (process.env.VOBIZ_AUTH_TOKEN || '').trim(),
  number: (process.env.VOBIZ_NUMBER || '').trim(),
  appName: (process.env.VOBIZ_APP_NAME || 'Vobiz_Flutter_Push_Bridge').trim(),
  forceAttach: process.env.FORCE_ATTACH === 'true',
  ringSeconds: clampInt(process.env.RING_SECONDS, 45, 15, 120),
  callerIdMode: (process.env.CALLER_ID_MODE || 'number').trim().toLowerCase(),
  headerStyle: (process.env.SIP_HEADER_STYLE || 'suffix').trim().toLowerCase(),
  alwaysRing: csv(process.env.ALWAYS_RING),
  stateFile: path.join(HERE, 'bridge-state.json'),
};
const verifySignatures = Boolean(config.authToken) && process.env.VERIFY_SIGNATURES !== 'false';

/** Seconds of ringback played between two dial attempts (one cadence of ringback.wav). */
const RINGBACK_SECONDS = 3;
/** After the user taps Accept, the app needs time to start and sign in. */
const ACCEPTED_GRACE_SECONDS = 60;
const INSTANCE = crypto.randomBytes(6).toString('hex');

// ── State: the app's key and the registered devices, kept across restarts ────

const state = loadState();
if (process.env.BRIDGE_KEY) state.bridgeKey = process.env.BRIDGE_KEY.trim();
if (!state.bridgeKey) state.bridgeKey = crypto.randomBytes(18).toString('base64url');
saveState();

/** Inbound calls in progress, by Vobiz CallUUID. Kept in memory only. */
const calls = new Map();
const ringback = makeRingbackWav();

// ── HTTP server ──────────────────────────────────────────────────────────────

const routes = {
  'GET /': (req, res) => sendText(res, 200, 'Vobiz push bridge is running.\n'),
  'GET /health': (req, res) => sendJson(res, 200, { ok: true, service: 'vobiz-push-bridge', instance: INSTANCE }),
  'GET /ringback.wav': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': ringback.length, 'Cache-Control': 'public, max-age=3600' });
    res.end(ringback);
  },
  // Vobiz webhooks
  'POST /answer': vobiz(onAnswer),
  'GET /answer': vobiz(onAnswer),
  'POST /dial-result': vobiz(onDialResult),
  'POST /hangup': vobiz(onHangup),
  'GET /hangup': vobiz(onHangup),
  // The app
  'POST /push/register': withBridgeKey(onRegister),
  'POST /push/unregister': withBridgeKey(onUnregister),
  'POST /push/test': withBridgeKey(onTestCall),
  'POST /push/accept': onAccept,
  'POST /push/decline': onDecline,
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://localhost');
  const handler = routes[`${req.method} ${url.pathname}`];
  if (!handler) return sendJson(res, 404, { error: 'Not found' });
  try {
    await handler(req, res, url);
  } catch (error) {
    log('!!', `${req.method} ${url.pathname} failed: ${error.stack || error}`);
    if (!res.headersSent) {
      if (url.pathname === '/answer' || url.pathname === '/dial-result') {
        sendXml(res, '<Speak>Sorry, something went wrong. Please try again.</Speak><Hangup/>');
      } else {
        sendJson(res, 500, { error: 'Internal error' });
      }
    }
  }
});

server.listen(config.port, async () => {
  console.log('');
  log('ok', `Vobiz push bridge listening on http://localhost:${config.port}`);
  await startupChecks();
});

setInterval(() => {
  const cutoff = Date.now() - 10 * 60 * 1000;
  for (const [id, call] of calls) if (call.createdAt < cutoff) calls.delete(id);
}, 60 * 1000).unref();

// ── Vobiz webhooks ───────────────────────────────────────────────────────────

/** Inbound call: wake the app, then ring its endpoint. */
async function onAnswer(req, res, url, params) {
  if (isHangupEvent(params)) return onHangup(req, res, url, params);

  const id = params.CallUUID || params.CallUuid || crypto.randomUUID();
  let call = calls.get(id);
  if (call) {
    log('..', `Vobiz asked again for call ${short(id)}; dialling again`);
    return sendXml(res, dialXml(call, { ringback: call.attempts > 0 }));
  }

  const targets = ringTargets();
  if (!targets.length) {
    log('..', `Inbound call from ${params.From || 'unknown'}: no app has signed in, so the caller is told`);
    return sendXml(res, '<Speak>Sorry, nobody is signed in to take this call. Please try again later.</Speak><Hangup/>');
  }

  call = {
    id,
    key: crypto.randomBytes(16).toString('hex'),
    from: displayNumber(params.From),
    to: displayNumber(params.To),
    targets,
    createdAt: Date.now(),
    deadline: Date.now() + config.ringSeconds * 1000,
    attempts: 0,
    accepted: false,
    declined: false,
    finished: null,
    endedPushSent: false,
  };
  calls.set(id, call);
  log('->', `Inbound call ${short(id)} from ${call.from} to ${call.to}; ringing ${targets.join(', ')}`);

  // The answer URL must reply within 10 seconds, so the push gets 4.
  await withTimeout(pushToTargets(call, incomingPayload(call)), 4000, 'push');
  return sendXml(res, dialXml(call, { ringback: false }));
}

/** One dial attempt has finished; decide whether to try again. */
async function onDialResult(req, res, url, params) {
  const id = url.searchParams.get('call') || params.DialALegUUID || params.CallUUID;
  const call = calls.get(id);
  const status = String(params.DialStatus || '').toLowerCase();
  const cause = params.DialHangupCause || params.DialBLegHangupCause || '';
  if (!call) return sendXml(res, '<Hangup/>');

  const left = Math.round((call.deadline - Date.now()) / 1000);
  log('..', `Call ${short(id)} attempt ${call.attempts}: ${status || 'no status'}${cause ? ` (${cause})` : ''}, ${Math.max(left, 0)} s left`);

  if (status === 'completed') {
    finish(call, 'answered');
    return sendXml(res, '<Hangup/>');
  }
  if (status === 'cancel') {
    finish(call, 'caller hung up');
    await endRinging(call, 'caller_hung_up');
    return sendXml(res, '<Hangup/>');
  }
  if (status === 'busy' || call.declined) {
    finish(call, 'declined');
    await endRinging(call, 'declined');
    return sendXml(res, '<Hangup reason="busy"/>');
  }
  if (left <= RINGBACK_SECONDS + 2) {
    finish(call, 'missed');
    await endRinging(call, 'missed');
    return sendXml(res, '<Speak>Sorry, there was no answer. Please try again later.</Speak><Hangup/>');
  }
  // "failed" is what an endpoint that is not registered produces: the app
  // is still starting. Play ringback, then ring it again.
  return sendXml(res, dialXml(call, { ringback: true }));
}

/** The caller's leg has ended. Stop the phone ringing if it still is. */
async function onHangup(req, res, url, params) {
  const call = calls.get(params.CallUUID);
  if (call) {
    if (!call.finished) finish(call, `ended (${params.HangupCause || params.CallStatus || 'hangup'})`);
    await endRinging(call, call.finished === 'answered' ? 'completed' : 'caller_hung_up');
  }
  sendText(res, 200, 'OK');
}

function dialXml(call, { ringback }) {
  call.attempts += 1;
  const base = publicBase();
  const ringFor = Math.max(10, Math.round((call.deadline - Date.now()) / 1000));
  const action = `${base}/dial-result?call=${encodeURIComponent(call.id)}`;
  const callerId = config.callerIdMode === 'number' && call.to ? ` callerId="${esc(call.to)}"` : '';
  const users = call.targets
    .map((user) => `    <User sipHeaders="${esc(sipHeaders(call))}">sip:${esc(user)}@registrar.vobiz.ai</User>`)
    .join('\n');
  const pre = ringback
    ? `  <PreAnswer><Play>${esc(base)}/ringback.wav</Play></PreAnswer>\n`
    : '';
  return `${pre}  <Dial${callerId} timeout="${ringFor}" timeLimit="14400" action="${esc(action)}" method="POST" redirect="true">\n${users}\n  </Dial>`;
}

/**
 * Metadata on the SIP INVITE, so the app can match the call to the push it
 * already showed. Vobiz's docs disagree on the key format ("RefX-VH=" on the
 * SIP headers page, "Ref=" in the Dial examples), so it is configurable; the
 * app falls back to matching the caller's number when neither arrives.
 */
function sipHeaders(call) {
  const caller = call.from.replace(/\D/g, '');
  const pairs = config.headerStyle === 'plain'
    ? [`PushRef=${call.id}`, caller && `Caller=${caller}`]
    : [`PushRefX-VH=${call.id}`, caller && `CallerX-VH=${caller}`];
  return pairs.filter(Boolean).join(',');
}

function isHangupEvent(params) {
  const event = String(params.Event || '').toLowerCase();
  const status = String(params.CallStatus || '').toLowerCase();
  return event === 'hangup' || ['completed', 'busy', 'failed', 'no-answer', 'canceled', 'cancel'].includes(status);
}

function finish(call, outcome) {
  if (!call.finished) {
    call.finished = outcome;
    log('ok', `Call ${short(call.id)} finished: ${outcome}`);
  }
}

/** Who rings for an inbound call: every endpoint an app registered, plus ALWAYS_RING. */
function ringTargets() {
  const names = new Set(Object.keys(state.devices).filter((u) => state.devices[u].length));
  for (const user of config.alwaysRing) names.add(user);
  return [...names];
}

// ── The app's requests ───────────────────────────────────────────────────────

/** The app signed in: remember which endpoint it is and where to push. */
async function onRegister(req, res, url, body) {
  const username = endpointUsername(body.username);
  if (!USERNAME_RE.test(username)) return sendJson(res, 400, { error: 'username must be the SIP endpoint username' });
  const token = typeof body.token === 'string' && body.token.length > 20 ? body.token : null;

  // One device belongs to one endpoint: drop this token from any other.
  if (token) {
    for (const [user, devices] of Object.entries(state.devices)) {
      state.devices[user] = devices.filter((d) => d.token !== token);
      if (!state.devices[user].length) delete state.devices[user];
    }
  }
  const devices = (state.devices[username] || []).filter((d) => (token ? d.token !== token : d.token));
  devices.unshift({
    token,
    platform: String(body.platform || 'android').slice(0, 20),
    app: String(body.app || '').slice(0, 120),
    registeredAt: new Date().toISOString(),
  });
  state.devices[username] = devices.slice(0, 3);
  saveState();

  const warning = await endpointWarning(username);
  log('ok', `Registered ${username}${token ? ` for push (token ${mask(token)})` : ' without push (no Firebase token)'}`);
  if (warning) log('!!', warning);
  sendJson(res, 200, { ok: true, username, push: Boolean(token), warning: warning || undefined });
}

async function onUnregister(req, res, url, body) {
  const username = endpointUsername(body.username);
  const before = (state.devices[username] || []).length;
  state.devices[username] = (state.devices[username] || []).filter((d) => body.token && d.token !== body.token);
  if (!state.devices[username].length) delete state.devices[username];
  saveState();
  log('ok', `Unregistered ${username || '(unknown)'} (${before} device record${before === 1 ? '' : 's'} before)`);
  sendJson(res, 200, { ok: true });
}

/** A pretend incoming call, to try the push path without dialling a real number. */
async function onTestCall(req, res, url, body) {
  const username = endpointUsername(body.username);
  const delay = clampInt(body.delay_seconds, 10, 0, 60);
  const targets = username ? [username] : ringTargets();
  const devices = targets.flatMap((u) => (state.devices[u] || []).filter((d) => d.token));
  if (!devices.length) return sendJson(res, 409, { error: 'No device with a push token is registered for that endpoint' });

  const call = {
    id: crypto.randomUUID(),
    key: crypto.randomBytes(16).toString('hex'),
    from: 'Test call',
    to: '',
    targets,
    createdAt: Date.now() + delay * 1000,
    deadline: Date.now() + (delay + 30) * 1000,
    attempts: 0,
    accepted: false,
    declined: false,
    finished: null,
    endedPushSent: false,
    test: true,
  };
  calls.set(call.id, call);
  log('->', `Test call ${short(call.id)} for ${targets.join(', ')} in ${delay} s`);
  setTimeout(() => pushToTargets(call, incomingPayload(call)).catch(() => {}), delay * 1000);
  sendJson(res, 200, { ok: true, call_id: call.id, sending_in_seconds: delay });
}

/** The user tapped Accept: give the app time to start and sign in. */
async function onAccept(req, res) {
  const body = await readJson(req);
  const call = callFor(body);
  if (!call) return sendJson(res, 404, { error: 'Unknown call' });
  call.accepted = true;
  call.deadline = Math.max(call.deadline, call.createdAt + ACCEPTED_GRACE_SECONDS * 1000);
  log('ok', `Call ${short(call.id)} accepted on the phone; waiting for the app to sign in`);
  sendJson(res, 200, { ok: true, test: Boolean(call.test) });
}

/** The user tapped Decline: the next dial result hangs up with "busy". */
async function onDecline(req, res) {
  const body = await readJson(req);
  let call = callFor(body);
  // Declined in the app without a push (no call key): find it by caller.
  if (!call && keyMatches(req)) {
    const user = endpointUsername(body.username);
    const caller = String(body.caller || '').replace(/\D/g, '');
    call = [...calls.values()]
      .filter((c) => !c.finished && c.targets.includes(user))
      .filter((c) => !caller || c.from.replace(/\D/g, '').endsWith(caller.slice(-10)))
      .sort((a, b) => b.createdAt - a.createdAt)[0];
  }
  if (!call) return sendJson(res, 404, { error: 'Unknown call' });
  call.declined = true;
  log('ok', `Call ${short(call.id)} declined on the phone`);
  sendJson(res, 200, { ok: true });
}

function callFor(body) {
  const call = calls.get(String(body.call_id || ''));
  if (!call || !safeEqual(String(body.call_key || ''), call.key)) return null;
  return call;
}

// ── Push messages (Firebase Cloud Messaging HTTP v1) ─────────────────────────

function incomingPayload(call) {
  return {
    type: 'incoming_call',
    call_id: call.id,
    call_key: call.key,
    caller: call.from,
    callee: call.to,
    server: publicBase(),
    sent_at: String(Date.now()),
    expires_at: String(call.deadline),
    ...(call.test ? { test: '1' } : {}),
  };
}

async function endRinging(call, reason) {
  if (call.endedPushSent) return;
  call.endedPushSent = true;
  await withTimeout(pushToTargets(call, { type: 'call_ended', call_id: call.id, reason }), 4000, 'push');
}

async function pushToTargets(call, data) {
  const devices = call.targets.flatMap((user) => (state.devices[user] || []).filter((d) => d.token));
  if (!devices.length) return;
  if (!firebase.ready) {
    log('!!', 'Not sending a push: FIREBASE_SERVICE_ACCOUNT is not set up');
    return;
  }
  await Promise.all(devices.map(async (device) => {
    const result = await sendPush(device.token, data);
    if (result.ok) {
      log('ok', `Push ${data.type} sent for call ${short(call.id)} to ${mask(device.token)}`);
    } else {
      log('!!', `Push to ${mask(device.token)} failed: ${result.status} ${result.code || ''} ${result.message || ''}`);
      if (result.code === 'UNREGISTERED' || result.status === 404) forgetToken(device.token);
    }
  }));
}

const firebase = { ready: false, projectId: '', clientEmail: '', privateKey: '', accessToken: '', expiresAt: 0 };

function loadServiceAccount() {
  if (!config.serviceAccountFile) return 'FIREBASE_SERVICE_ACCOUNT is not set';
  let json;
  try {
    json = JSON.parse(fs.readFileSync(path.resolve(HERE, config.serviceAccountFile), 'utf8'));
  } catch (error) {
    return `cannot read ${config.serviceAccountFile}: ${error.message}`;
  }
  if (json.type !== 'service_account' || !json.private_key || !json.client_email || !json.project_id) {
    return `${config.serviceAccountFile} is not a service account key`;
  }
  Object.assign(firebase, { ready: true, projectId: json.project_id, clientEmail: json.client_email, privateKey: json.private_key });
  return null;
}

async function googleAccessToken() {
  if (firebase.accessToken && Date.now() < firebase.expiresAt - 5 * 60 * 1000) return firebase.accessToken;
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: firebase.clientEmail,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const signature = crypto.createSign('RSA-SHA256').update(`${header}.${claims}`).sign(firebase.privateKey);
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(signature)}`,
    }),
    signal: AbortSignal.timeout(8000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.access_token) {
    throw new Error(`Google rejected the service account (${response.status} ${body.error || ''} ${body.error_description || ''})`.trim());
  }
  firebase.accessToken = body.access_token;
  firebase.expiresAt = Date.now() + (body.expires_in || 3600) * 1000;
  return firebase.accessToken;
}

async function sendPush(token, data, { validateOnly = false } = {}) {
  try {
    const accessToken = await googleAccessToken();
    const response = await fetch(`https://fcm.googleapis.com/v1/projects/${firebase.projectId}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        validate_only: validateOnly,
        message: {
          token,
          data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
          // Data-only and high priority: Android wakes the app even when it
          // is closed, and the app draws the call screen itself.
          android: { priority: 'HIGH', ttl: `${config.ringSeconds}s` },
        },
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (response.ok) return { ok: true };
    const body = await response.json().catch(() => ({}));
    const detail = (body.error?.details || []).find((d) => d.errorCode);
    return { ok: false, status: response.status, code: detail?.errorCode || body.error?.status, message: body.error?.message };
  } catch (error) {
    return { ok: false, status: 0, code: error.name === 'TimeoutError' ? 'TIMEOUT' : 'ERROR', message: error.message };
  }
}

function forgetToken(token) {
  for (const [user, devices] of Object.entries(state.devices)) {
    const kept = devices.filter((d) => d.token !== token);
    if (kept.length !== devices.length) {
      log('..', `Removed an expired push token from ${user}; the app registers a new one when it next signs in`);
      // Keep the endpoint ringing even without a token.
      state.devices[user] = kept.length ? kept : [{ token: null, platform: 'android', app: '', registeredAt: new Date().toISOString() }];
    }
  }
  saveState();
}

// ── Vobiz: signatures, account set-up ────────────────────────────────────────

/** Parses a Vobiz webhook and, when an Auth Token is set, checks its signature. */
function vobiz(handler) {
  return async (req, res, url) => {
    const raw = await readBody(req);
    const params = Object.fromEntries(new URLSearchParams(url.search));
    const type = String(req.headers['content-type'] || '');
    if (type.includes('application/json')) {
      try { Object.assign(params, JSON.parse(raw || '{}')); } catch { /* ignore */ }
    } else if (raw) {
      Object.assign(params, Object.fromEntries(new URLSearchParams(raw)));
    }
    if (verifySignatures && !signatureValid(req, url)) {
      log('!!', `Rejected ${url.pathname}: no valid X-Vobiz-Signature (set VERIFY_SIGNATURES=false to skip this check while testing)`);
      return sendText(res, 403, 'Invalid signature');
    }
    return handler(req, res, url, params);
  };
}

/**
 * Vobiz signs base64(HMAC-SHA256(authToken, url + "." + nonce)) (V3) or
 * url + nonce (V2), where url is the address it called. Whether the query
 * string is part of it is not documented, so both forms are accepted.
 */
function signatureValid(req, url) {
  const base = config.publicUrl;
  if (!base) return true;
  const candidates = [`${base}${url.pathname}`, `${base}${url.pathname}${url.search}`];
  const checks = [
    ['x-vobiz-signature-v3', 'x-vobiz-signature-v3-nonce', '.'],
    ['x-vobiz-signature-ma-v3', 'x-vobiz-signature-ma-v3-nonce', '.'],
    ['x-vobiz-signature-v2', 'x-vobiz-signature-v2-nonce', ''],
  ];
  for (const [sigHeader, nonceHeader, separator] of checks) {
    const signature = String(req.headers[sigHeader] || '');
    const nonce = String(req.headers[nonceHeader] || '');
    if (!signature || !nonce) continue;
    for (const candidate of candidates) {
      const expected = crypto.createHmac('sha256', config.authToken).update(candidate + separator + nonce).digest('base64');
      if (safeEqual(signature, expected)) return true;
    }
  }
  return false;
}

async function vobizApi(method, pathname, body) {
  const response = await fetch(`${config.vobizApi}/api/v1/Account/${encodeURIComponent(config.authId)}${pathname}`, {
    method,
    headers: { 'X-Auth-ID': config.authId, 'X-Auth-Token': config.authToken, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10000),
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (!response.ok) throw new Error(`${method} ${pathname} → ${response.status} ${text.slice(0, 200)}`);
  return json;
}

/** Every object of a paged Vobiz list (`?limit=&offset=`, at most 100 a page). */
async function listAll(collection) {
  const all = [];
  for (let offset = 0; offset < 5000; offset += 100) {
    const page = await vobizApi('GET', `${collection}?limit=100&offset=${offset}`);
    const objects = page?.objects || [];
    all.push(...objects);
    const total = page?.meta?.total_count ?? 0;
    if (!objects.length || offset + objects.length >= total) break;
  }
  return all;
}

/** Points VOBIZ_NUMBER at this server: finds or creates the application, then attaches the number. */
async function linkVobizNumber() {
  const base = config.publicUrl;
  const want = { answer_url: `${base}/answer`, answer_method: 'POST', hangup_url: `${base}/hangup`, hangup_method: 'POST' };

  let app = (await listAll('/Application/')).find((a) => a.app_name === config.appName) || null;
  if (!app) {
    const created = await vobizApi('POST', '/Application/', { app_name: config.appName, ...want });
    app = { app_id: created?.app_id || created?.application_id || created?.id, app_name: config.appName };
    log('ok', `Vobiz: created application ${config.appName} (${app.app_id})`);
  } else if (app.answer_url !== want.answer_url || app.hangup_url !== want.hangup_url) {
    await vobizApi('POST', `/Application/${app.app_id}/`, want);
    log('ok', `Vobiz: application ${config.appName} now answers at ${want.answer_url}`);
  } else {
    log('ok', `Vobiz: application ${config.appName} already answers at ${want.answer_url}`);
  }
  if (!app.app_id) throw new Error('Vobiz did not return the new application ID');

  const e164 = config.number.startsWith('+') ? config.number : `+${config.number}`;
  let number = null;
  for (let page = 1; page <= 50 && !number; page += 1) {
    const list = await vobizApi('GET', `/numbers?page=${page}&per_page=100`);
    const items = list?.items || [];
    number = items.find((n) => n.e164 === e164) || null;
    const perPage = list?.per_page || items.length;
    if (!items.length || page * perPage >= (list?.total ?? 0)) break;
  }
  if (!number) throw new Error(`${e164} is not a number on account ${config.authId}`);
  const current = String(number.application_id || number.app_id || '');
  if (current === String(app.app_id)) {
    log('ok', `Vobiz: ${e164} already rings this bridge`);
    return;
  }
  if (current && !config.forceAttach) {
    log('!!', `Vobiz: ${e164} is attached to another application (${current}); left as it is. Set FORCE_ATTACH=true to move it here.`);
    return;
  }
  await vobizApi('POST', `/numbers/${encodeURIComponent(e164)}/application`, { application_id: String(app.app_id) });
  log('ok', `Vobiz: ${e164} now rings this bridge`);
}

const endpointCache = { at: 0, names: null };

/** Warns when an app registers an endpoint that is not on VOBIZ_AUTH_ID's account. */
async function endpointWarning(username) {
  if (!config.authId || !config.authToken) return null;
  try {
    if (!endpointCache.names || Date.now() - endpointCache.at > 60 * 1000) {
      const endpoints = await listAll('/Endpoint/');
      endpointCache.names = new Set(endpoints.filter((e) => e.username).map((e) => String(e.username).toLowerCase()));
      endpointCache.at = Date.now();
    }
    return endpointCache.names.has(username.toLowerCase())
      ? null
      : `${username} is not an endpoint on ${config.authId}; inbound calls to ${config.number || 'your number'} may not reach it`;
  } catch {
    return null;
  }
}

// ── Start-up checks ──────────────────────────────────────────────────────────

async function startupChecks() {
  const saProblem = loadServiceAccount();
  if (saProblem) {
    log('!!', `Firebase: ${saProblem}. Calls still ring the app while it is open, but closed apps will not wake.`);
  } else {
    // A dry run with a made-up token: Google answers "invalid token" only
    // after accepting the credentials, which is what this checks.
    const result = await sendPush('bridge-startup-check', { type: 'check' }, { validateOnly: true });
    if (result.ok || result.status === 400 || result.status === 404) {
      log('ok', `Firebase: service account for project ${firebase.projectId} works`);
    } else {
      firebase.ready = false;
      log('!!', `Firebase: ${result.status} ${result.code || ''} ${result.message || ''}`);
    }
  }

  if (!config.publicUrl) {
    log('!!', 'PUBLIC_URL is not set. Start a tunnel to this port and put its https address in .env, then restart.');
  } else {
    try {
      const response = await fetch(`${config.publicUrl}/health`, { signal: AbortSignal.timeout(10000) });
      const body = await response.json().catch(() => ({}));
      if (body.instance === INSTANCE) {
        log('ok', `Tunnel: ${config.publicUrl} reaches this server`);
      } else {
        log('!!', `Tunnel: ${config.publicUrl} answered, but not from this server (status ${response.status}). Is PUBLIC_URL current?`);
      }
    } catch (error) {
      log('!!', `Tunnel: cannot reach ${config.publicUrl}/health (${error.message}). Is the tunnel running?`);
    }
  }

  if (config.authId && config.authToken && config.number && config.publicUrl) {
    try {
      await linkVobizNumber();
    } catch (error) {
      log('!!', `Vobiz: could not point ${config.number} at this bridge: ${error.message}`);
    }
  } else if (config.number || config.authId) {
    log('..', 'Vobiz: set VOBIZ_AUTH_ID, VOBIZ_AUTH_TOKEN, VOBIZ_NUMBER and PUBLIC_URL to link the number automatically');
  }

  log(verifySignatures ? 'ok' : '..', verifySignatures
    ? 'Webhooks: Vobiz signatures are checked'
    : 'Webhooks: signatures are not checked (set VOBIZ_AUTH_TOKEN to check them)');

  const registered = Object.entries(state.devices)
    .map(([user, devices]) => `${user} (${devices.filter((d) => d.token).length ? 'push' : 'no push'})`);
  log('..', `Apps registered: ${registered.length ? registered.join(', ') : 'none yet'}`);

  console.log('');
  console.log('  In the app: Identity tab → Incoming calls → Push server, paste this line:');
  console.log('');
  console.log(`    ${config.publicUrl || 'https://<your-tunnel>'}#key=${state.bridgeKey}`);
  console.log('');
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function withBridgeKey(handler) {
  return async (req, res, url) => {
    if (!keyMatches(req)) return sendJson(res, 401, { error: 'Wrong or missing bridge key' });
    return handler(req, res, url, await readJson(req));
  };
}

function keyMatches(req) {
  const header = String(req.headers['x-bridge-key'] || '');
  return Boolean(header) && safeEqual(header, state.bridgeKey);
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 64 * 1024) {
        reject(new Error('Request body too large'));
        req.destroy();
      } else {
        chunks.push(chunk);
      }
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function readJson(req) {
  const raw = await readBody(req);
  try {
    const json = raw ? JSON.parse(raw) : {};
    return json && typeof json === 'object' ? json : {};
  } catch {
    return {};
  }
}

function sendXml(res, inner) {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<Response>\n${inner}\n</Response>\n`;
  res.writeHead(200, { 'Content-Type': 'application/xml' });
  res.end(xml);
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function sendText(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(text);
}

function publicBase() {
  return config.publicUrl || `http://localhost:${config.port}`;
}

/** `sip:play123@registrar.vobiz.ai` → `play123`. */
function endpointUsername(value) {
  return String(value || '').trim().replace(/^sip:/i, '').split('@')[0];
}

/** Numbers as people read them: +91… for Indian numbers that arrive without a prefix. */
function displayNumber(value) {
  const raw = String(value || '').trim().replace(/^sip:/i, '').split('@')[0];
  if (!raw) return '';
  if (raw.startsWith('+')) return raw;
  const digits = raw.replace(/\D/g, '');
  if (!digits || digits.length !== raw.length) return raw;
  if (digits.length === 11 && digits.startsWith('0')) return `+91${digits.slice(1)}`;
  if (digits.length === 10) return `+91${digits}`;
  return `+${digits}`;
}

function esc(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function b64url(value) {
  return Buffer.from(value).toString('base64url');
}

function mask(token) {
  return token ? `${token.slice(0, 6)}…${token.slice(-4)}` : '(none)';
}

function short(id) {
  return String(id).slice(0, 8);
}

function csv(value) {
  return String(value || '').split(',').map((s) => endpointUsername(s)).filter((s) => USERNAME_RE.test(s));
}

function clampInt(value, fallback, min, max) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

async function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => {
      log('!!', `${label} took longer than ${ms} ms; carrying on without waiting`);
      resolve();
    }, ms);
  });
  try {
    await Promise.race([promise.catch((e) => log('!!', `${label} failed: ${e.message}`)), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

function log(tag, message) {
  const time = new Date().toTimeString().slice(0, 8);
  console.log(`[${time}] ${tag.padEnd(2)} ${message}`);
}

function loadEnvFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return;
  }
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!match || match[2].startsWith('#')) continue;
    const value = match[2].replace(/^(['"])(.*)\1$/, '$2');
    if (process.env[match[1]] === undefined) process.env[match[1]] = value;
  }
}

function loadState() {
  try {
    const json = JSON.parse(fs.readFileSync(config.stateFile, 'utf8'));
    return { bridgeKey: json.bridgeKey || '', devices: json.devices && typeof json.devices === 'object' ? json.devices : {} };
  } catch {
    return { bridgeKey: '', devices: {} };
  }
}

function saveState() {
  const tmp = `${config.stateFile}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, config.stateFile);
}

/**
 * Three seconds of the Indian ringback tone (400 Hz modulated at 25 Hz;
 * 0.4 s on, 0.2 s off, 0.4 s on, 2 s off) as 8 kHz 16-bit mono WAV.
 */
function makeRingbackWav() {
  const rate = 8000;
  const samples = rate * RINGBACK_SECONDS;
  const pcm = Buffer.alloc(samples * 2);
  const bursts = [[0, 0.4], [0.6, 1.0]];
  for (let i = 0; i < samples; i += 1) {
    const t = i / rate;
    const burst = bursts.find(([start, end]) => t >= start && t < end);
    let value = 0;
    if (burst) {
      const edge = Math.min(t - burst[0], burst[1] - t);
      const fade = Math.min(1, edge / 0.005);
      value = 0.3 * fade * (Math.sin(2 * Math.PI * 375 * t) + Math.sin(2 * Math.PI * 425 * t)) / 2;
    }
    pcm.writeInt16LE(Math.round(value * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write('data', 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}
