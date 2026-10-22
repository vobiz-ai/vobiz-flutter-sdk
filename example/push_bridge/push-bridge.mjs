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
 *      which shows a full-screen incoming-call screen and signs in;
 *   2. holds the caller on ringback (early media) for up to
 *      PUSH_WAIT_SECONDS, until the pushed phones report their SIP
 *      registration (POST /push/registered). It dials the moment they do,
 *      and at the end of the wait without them if they do not;
 *   3. rings every target at once in ONE <Dial>: the app endpoints, the
 *      ALWAYS_RING endpoints (e.g. a browser) and the route's PSTN numbers.
 *      The first to answer wins; Vobiz cancels the rest. The Dial is never
 *      restarted, so a ringing browser or phone is not cut off.
 *
 * Webhooks must carry a valid Vobiz signature (PUBLIC_URL and
 * VOBIZ_AUTH_TOKEN are required); phones pair once with the bridge key and
 * then use their own device token. README.md has the app ↔ bridge protocol.
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

/**
 * Builds a bridge without starting it. `options.env` replaces process.env,
 * `options.stateFile` the state file, and `options.deps` lets tests swap the
 * outside world: `sendPush(token, data)` for Firebase, `vobizApi(method,
 * path, body)` for the Vobiz REST API, `log(tag, message)`.
 */
export function createBridge(options = {}) {
  const env = options.env || process.env;
  const deps = options.deps || {};
  const log = deps.log || defaultLog;
  const config = {
    port: clampInt(env.PORT, 8787, 1, 65535),
    publicUrl: (env.PUBLIC_URL || '').trim().replace(/\/+$/, ''),
    serviceAccountFile: (env.FIREBASE_SERVICE_ACCOUNT || '').trim(),
    vobizApi: (env.VOBIZ_API_URL || 'https://api.vobiz.ai').trim().replace(/\/+$/, ''),
    authId: (env.VOBIZ_AUTH_ID || '').trim(),
    authToken: (env.VOBIZ_AUTH_TOKEN || '').trim(),
    number: (env.VOBIZ_NUMBER || '').trim(),
    appName: (env.VOBIZ_APP_NAME || 'Vobiz_Flutter_Push_Bridge').trim(),
    forceAttach: env.FORCE_ATTACH === 'true',
    ringSeconds: clampInt(env.RING_SECONDS, 45, 15, 120),
    // How long the caller waits on ringback for the woken app to sign in
    // before the Dial starts without it. 3 to 9 seconds: longer delays every
    // other target (browser, PSTN) by as much.
    pushWaitSeconds: clampInt(env.PUSH_WAIT_SECONDS, 5, 3, 9),
    callerIdMode: (env.CALLER_ID_MODE || 'number').trim().toLowerCase(),
    headerStyle: (env.SIP_HEADER_STYLE || 'suffix').trim().toLowerCase(),
    alwaysRing: csv(env.ALWAYS_RING),
    routes: parseRoutes(env.ROUTES),
    stateFile: options.stateFile || path.join(HERE, 'bridge-state.json'),
  };
  // Webhooks are checked unless the operator explicitly opts out for local
  // testing. Without PUBLIC_URL and the Auth Token nothing can be checked, so
  // the bridge refuses to start rather than quietly accepting anything.
  const allowUnsigned = env.ALLOW_UNSIGNED_WEBHOOKS === 'true';
  const verifySignatures = !allowUnsigned;
  const problems = configProblems(config, env, allowUnsigned);
  if (problems.length) {
    const error = new Error(`Push bridge is not configured safely:\n  - ${problems.join('\n  - ')}`);
    error.code = 'BRIDGE_CONFIG';
    throw error;
  }

  /**
   * A transfer to /dial-now this close to the end of the wait could race the
   * hold XML's own <Redirect> to /dial-now and restart a Dial that has just
   * started, so the bridge lets the Redirect dial instead.
   */
  const TRANSFER_MARGIN_MS = 1000;
  /**
   * How long a webhook nonce is remembered. Vobiz nonces are random, not
   * time-based, and nothing in the request is timestamped, so replay
   * protection is "never accept the same nonce twice" within this window;
   * calls are long over by then.
   */
  const NONCE_TTL_MS = 30 * 60 * 1000;
  const INSTANCE = crypto.randomBytes(6).toString('hex');

  // ── State: the app's key and the registered devices, kept across restarts ────

  const state = loadState();
  if (env.BRIDGE_KEY) state.bridgeKey = env.BRIDGE_KEY.trim();
  const keyIsNew = !state.bridgeKey;
  if (keyIsNew) state.bridgeKey = crypto.randomBytes(18).toString('base64url');
  // Signs the per-call part of the Dial callback paths (see callRef()).
  if (!state.webhookSecret) state.webhookSecret = crypto.randomBytes(32).toString('base64url');
  pruneNonces();
  saveState();

  /** Inbound calls in progress, by Vobiz CallUUID. Kept in memory only. */
  const calls = new Map();
  // Ringback for exactly the push wait: 0.4 s on, 0.2 s off, 0.4 s on, 2 s off.
  const waitRingback = makeToneWav(config.pushWaitSeconds, ringbackBursts(config.pushWaitSeconds));
  // Indian busy tone: 400 Hz, 0.75 s on, 0.75 s off.
  const busyTone = makeToneWav(3, [[0, 0.75], [1.5, 2.25]]);

  // ── HTTP server ──────────────────────────────────────────────────────────────

  const routes = {
    'GET /': (req, res) => sendText(res, 200, 'Vobiz push bridge is running.\n'),
    'GET /health': (req, res) => sendJson(res, 200, { ok: true, service: 'vobiz-push-bridge', instance: INSTANCE }),
    'GET /wait.wav': (req, res) => sendWav(res, waitRingback),
    'GET /busy.wav': (req, res) => sendWav(res, busyTone),
    // Vobiz webhooks
    'POST /answer': vobiz(onAnswer),
    'GET /answer': vobiz(onAnswer),
    // Per call: /dial-result/<call id>.<tag>, so the signed URL names the call
    'POST /dial-result/*': vobiz(onDialResult),
    'POST /dial-events/*': vobiz(onDialEvent),
    'POST /hangup': vobiz(onHangup),
    'GET /hangup': vobiz(onHangup),
    // The app
    'POST /push/register': onRegister,
    'POST /push/unregister': onUnregister,
    'POST /push/test': onTestCall,
    'POST /push/accept': onAccept,
    'POST /push/registered': onRegistered,
    // The one Dial: the hold XML redirects here when the wait ends, or the
    // caller's leg is transferred here when the app reports it is registered
    'POST /dial-now/*': vobiz(onDialNow),
    // Where a call is transferred to when the user taps Decline
    'POST /declined/*': vobiz(onDeclinedXml),
    'POST /push/decline': onDecline,
  };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://localhost');
    const prefix = url.pathname.split('/').slice(0, 2).join('/');
    const handler = routes[`${req.method} ${url.pathname}`]
      || (url.pathname.split('/').length === 3 && routes[`${req.method} ${prefix}/*`]);
    if (!handler) return sendJson(res, 404, { error: 'Not found' });
    try {
      await handler(req, res, url);
    } catch (error) {
      log('!!', `${req.method} ${url.pathname} failed: ${error.stack || error}`);
      if (!res.headersSent) {
        if (url.pathname === '/answer' || /^\/(dial-result|dial-now|declined)\//.test(url.pathname)) {
          sendXml(res, '<Speak>Sorry, something went wrong. Please try again.</Speak><Hangup/>');
        } else {
          sendJson(res, 500, { error: 'Internal error' });
        }
      }
    }
  });

  let sweeper = null;

  /** Starts listening. `port` 0 picks a free port (tests). Resolves with the port. */
  function start({ port = config.port, checks = true } = {}) {
    sweeper = setInterval(() => {
      const cutoff = Date.now() - 10 * 60 * 1000;
      for (const [id, call] of calls) if (call.createdAt < cutoff) calls.delete(id);
    }, 60 * 1000);
    sweeper.unref();
    return new Promise((resolve) => {
      server.listen(port, async () => {
        const actual = server.address().port;
        if (checks) {
          console.log('');
          log('ok', `Vobiz push bridge listening on http://localhost:${actual}`);
          await startupChecks();
        }
        resolve(actual);
      });
    });
  }

  function close() {
    if (sweeper) clearInterval(sweeper);
    return new Promise((resolve) => server.close(() => resolve()));
  }

  // ── Vobiz webhooks ───────────────────────────────────────────────────────────

  /** Inbound call: wake the app, hold the caller briefly, then ring everyone at once. */
  async function onAnswer(req, res, url, params) {
    if (isHangupEvent(params)) return onHangup(req, res, url, params);

    const id = params.CallUUID || params.CallUuid || crypto.randomUUID();
    let call = calls.get(id);
    if (call) {
      log('..', `Vobiz asked again for call ${short(id)}`);
      return sendXml(res, call.dialStarted ? dialXml(call) : holdXml(call));
    }

    const { users: targets, numbers } = ringTargets(params.To);
    if (!targets.length && !numbers.length) {
      log('..', `Inbound call from ${params.From || 'unknown'}: no app has signed in, so the caller is told`);
      return sendXml(res, '<Speak>Sorry, nobody is signed in to take this call. Please try again later.</Speak><Hangup/>');
    }

    // Every endpoint rung is already on a call through this bridge.
    const lineBusy = targets.length > 0 && targets.every((user) => onCall(user));
    // Phones the push goes to. Waiting only makes sense if one of them can
    // be woken; an endpoint already on a call is registered already.
    const pushed = canPush() ? devicesOf(targets).filter((d) => d.token).length : 0;
    const waitSeconds = pushed && !lineBusy ? config.pushWaitSeconds : 0;
    const now = Date.now();
    call = {
      id,
      key: crypto.randomBytes(16).toString('hex'),
      from: displayNumber(params.From),
      to: displayNumber(params.To),
      targets,
      numbers,
      createdAt: now,
      // Until the Dial starts: the wait plus the ring. Then: the ring.
      deadline: now + (waitSeconds + config.ringSeconds) * 1000,
      waitUntil: now + waitSeconds * 1000,
      pushedDevices: pushed,
      // Phones that reported "registered" for this call (device ids, or one
      // anonymous entry per call-key report).
      registered: new Set(),
      transferred: false,
      dialStarted: false,
      lateRegistered: false,
      accepted: false,
      declined: false,
      bridged: false,
      finished: null,
      endedPushSent: false,
      lineBusy,
      over: false,
    };
    calls.set(id, call);
    const everyone = [...targets, ...numbers].join(', ');
    log('->', `Inbound call ${short(id)} from ${call.from} to ${call.to}; will ring ${everyone}`);

    // The push goes out in parallel; FCM never holds up the reply to Vobiz.
    background(pushToTargets(call, incomingPayload(call)), 'push');
    if (!waitSeconds) return sendXml(res, dialXml(call));
    log('..', `Call ${short(id)}: ringback for up to ${waitSeconds} s while ${pushed} phone(s) wake and sign in`);
    return sendXml(res, holdXml(call));
  }

  /**
   * The caller hears ringback as early media while the app wakes. When it
   * ends, Vobiz requests /dial-now (the Dial without the app). If the app
   * reports "registered" first, the caller's leg is transferred to /dial-now
   * at once and this document is abandoned (see onRegistered).
   */
  function holdXml(call) {
    const base = publicBase();
    return `  <PreAnswer><Play>${esc(base)}/wait.wav</Play></PreAnswer>\n  <Redirect method="POST">${esc(base)}/dial-now/${callRef(call.id)}</Redirect>`;
  }

  /** The single Dial attempt has ended: the call is answered, or it is over. */
  async function onDialResult(req, res, url, params) {
    const id = callIdFromPath(url);
    const call = id ? calls.get(id) : null;
    const status = String(params.DialStatus || '').toLowerCase();
    const cause = params.DialHangupCause || params.DialBLegHangupCause || '';
    if (!call) return sendXml(res, '<Hangup/>');
    if (call.finished === 'declined') return sendXml(res, declinedXml());
    log('..', `Call ${short(id)} Dial ended: ${status || 'no status'}${cause ? ` (${cause})` : ''}`);

    // "completed" is documented as "bridged, then ended", but Vobiz also sends it
    // when the app was rung and never answered (seen 2026-10-09: a 10 s
    // unanswered B-leg reported as completed / NORMAL_CLEARING). Only a
    // DialAnswer or DialConnected event on callbackUrl proves someone answered.
    if (status === 'completed' && call.bridged) {
      finish(call, 'answered');
      call.over = true;
      return sendXml(res, '<Hangup/>');
    }
    // Call waiting: the endpoint is on another call through this bridge, so
    // "busy" is the app's SIP stack refusing a second call.
    if (status === 'busy' && call.lineBusy && !call.accepted) {
      finish(call, 'busy');
      endRinging(call, 'busy');
      return sendXml(res, declinedXml());
    }
    if (status === 'cancel') {
      finish(call, 'caller hung up');
      endRinging(call, 'caller_hung_up');
      return sendXml(res, '<Hangup/>');
    }
    if (call.declined) {
      finish(call, 'declined');
      endRinging(call, 'declined');
      return sendXml(res, declinedXml());
    }
    // One Dial only: nobody answered (or every leg failed). No second attempt,
    // so a target that rang is never rung again from the start.
    finish(call, 'missed');
    endRinging(call, 'missed');
    return sendXml(res, '<Speak>Sorry, there was no answer. Please try again later.</Speak><Hangup/>');
  }

  /**
   * Live events for the leg that rings the app (the Dial's callbackUrl). An
   * answer or connected event is the only reliable proof the app picked up.
   */
  async function onDialEvent(req, res, url, params) {
    const id = callIdFromPath(url);
    const call = id ? calls.get(id) : null;
    const event = String(params.Event || '');
    const action = String(params.DialAction || '').toLowerCase();
    if (call) {
      if (action === 'answer' || action === 'connected' || event === 'DialAnswer' || event === 'DialConnected') {
        if (!call.bridged) {
          const by = endpointUsername(params.DialBLegTo || '');
          log('ok', `Call ${short(call.id)}: answered${by ? ` by ${by}` : ''}`);
          call.bridged = true;
          finish(call, 'answered');
          // Every phone that was pushed and has not got the call stops
          // ringing now, without a "missed call". The phone that answered
          // ignores this: it has the call (PushRef = call_id).
          if (!call.endedPushSent) {
            call.endedPushSent = true;
            background(pushToTargets(call, {
              type: 'call_ended',
              call_id: call.id,
              reason: 'answered_elsewhere',
              ...(by ? { answered_by: by } : {}),
            }), 'push');
          }
        }
      } else if (action === 'hangup' || event === 'DialHangup') {
        const cause = params.DialBLegHangupCauseName || params.DialBLegHangupCause || '';
        log('..', `Call ${short(call.id)}: ringing the app ended${cause ? ` (${cause})` : ''}`);
      }
    }
    sendText(res, 200, 'OK');
  }

  /** The caller's leg has ended. Stop the phone ringing if it still is. */
  async function onHangup(req, res, url, params) {
    const call = calls.get(params.CallUUID);
    if (call) {
      call.over = true;
      if (!call.finished) finish(call, `ended (${params.HangupCause || params.CallStatus || 'hangup'})`);
      endRinging(call, call.finished === 'answered' ? 'completed' : 'caller_hung_up');
    }
    sendText(res, 200, 'OK');
  }

  /**
   * The one Dial: every app endpoint (all routed users, whether or not their
   * app reported in time: an open app that did not report still rings, an
   * offline one just fails its leg), every ALWAYS_RING endpoint and the
   * route's PSTN numbers, all at once. The first to answer wins.
   */
  function dialXml(call) {
    call.dialStarted = true;
    call.deadline = Date.now() + config.ringSeconds * 1000;
    const base = publicBase();
    const action = `${base}/dial-result/${callRef(call.id)}`;
    const events = `${base}/dial-events/${callRef(call.id)}`;
    const callerId = config.callerIdMode === 'number' && call.to ? ` callerId="${esc(call.to)}"` : '';
    const legs = [
      ...call.targets.map((user) => `    <User sipHeaders="${esc(sipHeaders(call))}">sip:${esc(user)}@registrar.vobiz.ai</User>`),
      ...call.numbers.map((number) => `    <Number>${esc(number)}</Number>`),
    ].join('\n');
    return `  <Dial${callerId} timeout="${config.ringSeconds}" timeLimit="14400" action="${esc(action)}" method="POST" redirect="true" callbackUrl="${esc(events)}" callbackMethod="POST">\n${legs}\n  </Dial>`;
  }

  /**
   * Metadata on the SIP INVITE, so the app can match the call to the push it
   * already showed. PushRef is the push's call_id, on every <User>: the app
   * auto-answers an accepted call only when PushRef equals that call_id, never
   * by caller or callee number (with CALLER_ID_MODE=number every call shows
   * the same number). Vobiz's docs disagree on the key format ("RefX-VH=" on
   * the SIP headers page, "Ref=" in the Dial examples), so it is configurable.
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

  /** The `reason` the app is given for a call that is over. */
  function endReason(call) {
    const outcome = String(call.finished || '');
    if (outcome === 'answered') return 'answered_elsewhere';
    if (['declined', 'missed', 'busy'].includes(outcome)) return outcome;
    return 'caller_hung_up';
  }

  function finish(call, outcome) {
    if (!call.finished) {
      call.finished = outcome;
      log('ok', `Call ${short(call.id)} finished: ${outcome}`);
    }
  }

  /**
   * Who rings for an inbound call to `to`: `users`, the endpoints ROUTES
   * maps that number to plus ALWAYS_RING, and `numbers`, the route's PSTN
   * numbers. Without ROUTES, the one user that has registered a phone; with
   * several users and no ROUTES nobody is pushed, because the bridge cannot
   * know whose number was dialled.
   */
  function ringTargets(to) {
    const names = new Set();
    let numbers = [];
    if (config.routes.size) {
      const route = config.routes.get(displayNumber(to));
      for (const user of route?.users || []) names.add(user);
      numbers = route?.numbers || [];
    } else {
      const users = new Set(Object.values(state.devices).map((d) => d.username));
      if (users.size === 1) names.add([...users][0]);
      else if (users.size > 1) {
        log('!!', `Phones are registered for ${users.size} different endpoints (${[...users].join(', ')}) and ROUTES is not set, so none of them is rung for ${to || 'this call'}. Set ROUTES=<number>=<endpoint>,… in .env.`);
      }
    }
    for (const user of config.alwaysRing) names.add(user);
    return { users: [...names], numbers };
  }

  /** Whether a push can be sent at all (Firebase set up, or a test double). */
  function canPush() {
    return Boolean(deps.sendPush) || firebase.ready;
  }

  /** Whether `user` is on a call this bridge connected and that has not ended. */
  function onCall(user) {
    for (const c of calls.values()) if (c.bridged && !c.over && c.targets.includes(user)) return true;
    return false;
  }

  /** The registered phones of these endpoints. */
  function devicesOf(users) {
    return Object.entries(state.devices)
      .filter(([, d]) => users.includes(d.username))
      .map(([id, d]) => ({ id, ...d }));
  }

  // ── The app's requests ───────────────────────────────────────────────────────

  /**
   * The app signed in. A new phone pairs with the bridge key (X-Bridge-Key)
   * and gets its own device token back, which it sends from then on
   * (Authorization: Bearer <device_token>). Calls to an endpoint are pushed
   * only to the phones registered for it.
   */
  async function onRegister(req, res) {
    const device = deviceFromRequest(req);
    if (!device && !keyMatches(req)) return sendJson(res, 401, { error: 'Pair with the bridge key, or send this phone\'s device token' });
    const body = await readJson(req);
    const username = endpointUsername(body.username);
    if (!USERNAME_RE.test(username)) return sendJson(res, 400, { error: 'username must be the SIP endpoint username' });
    const token = typeof body.token === 'string' && body.token.length > 20 && body.token.length < 4096 ? body.token : null;

    const known = await endpointKnown(username);
    if (known === false) {
      log('!!', `Refused to register ${username}: not an endpoint on ${config.authId}`);
      return sendJson(res, 403, { error: `${username} is not an endpoint on this Vobiz account` });
    }
    if (known === null) return sendJson(res, 503, { error: 'Could not check the endpoint with Vobiz; try again' });

    let id = device?.id;
    let secret = null;
    if (!id) {
      id = crypto.randomBytes(9).toString('base64url');
      secret = crypto.randomBytes(24).toString('base64url');
    }
    // A Firebase token belongs to one phone: drop older records that carry it.
    if (token) {
      for (const [other, d] of Object.entries(state.devices)) if (other !== id && d.token === token) delete state.devices[other];
    }
    state.devices[id] = {
      username,
      token,
      secretHash: secret ? sha256(secret) : state.devices[id].secretHash,
      platform: String(body.platform || 'android').slice(0, 20),
      app: String(body.app || '').slice(0, 120),
      registeredAt: new Date().toISOString(),
    };
    saveState();

    log('ok', `Registered ${username} on device ${id}${token ? ` for push (token ${mask(token)})` : ' without push (no Firebase token)'}`);
    sendJson(res, 200, {
      ok: true,
      username,
      push: Boolean(token),
      device_id: id,
      // Only on pairing; the bridge keeps a hash and cannot show it again.
      ...(secret ? { device_token: `${id}.${secret}` } : {}),
      ...(known === undefined ? { warning: 'The bridge cannot check endpoints (VOBIZ_AUTH_ID is not set)' } : {}),
    });
  }

  /** Forget this phone (device token required). */
  async function onUnregister(req, res) {
    const device = deviceFromRequest(req);
    if (!device) return sendJson(res, 401, { error: 'Send this phone\'s device token' });
    delete state.devices[device.id];
    saveState();
    log('ok', `Unregistered device ${device.id} (${device.username})`);
    sendJson(res, 200, { ok: true });
  }

  /** A pretend incoming call to the asking phone only, to try the push path. */
  async function onTestCall(req, res) {
    const device = deviceFromRequest(req);
    if (!device) return sendJson(res, 401, { error: 'Send this phone\'s device token' });
    const body = await readJson(req);
    if (!device.token) return sendJson(res, 409, { error: 'This phone has no push token registered' });
    const delay = clampInt(body.delay_seconds, 10, 0, 60);

    const call = {
      id: crypto.randomUUID(),
      key: crypto.randomBytes(16).toString('hex'),
      from: 'Test call',
      to: '',
      targets: [device.username],
      onlyDevice: device.id,
      createdAt: Date.now() + delay * 1000,
      deadline: Date.now() + (delay + 30) * 1000,
      accepted: false,
      declined: false,
      finished: null,
      endedPushSent: false,
      test: true,
    };
    calls.set(call.id, call);
    log('->', `Test call ${short(call.id)} for device ${device.id} in ${delay} s`);
    setTimeout(() => pushToTargets(call, incomingPayload(call)).catch(() => {}), delay * 1000);
    sendJson(res, 200, { ok: true, call_id: call.id, sending_in_seconds: delay });
  }

  /**
   * The user tapped Accept. With one Dial there is no later attempt to hold
   * the call open for, so this only records it (and says if it is over).
   */
  async function onAccept(req, res) {
    const body = await readJson(req);
    const call = callFor(body);
    if (!call) return sendJson(res, 404, { error: 'Unknown call' });
    if (call.finished) return sendJson(res, 200, { ok: true, finished: true, reason: endReason(call) });
    call.accepted = true;
    log('ok', `Call ${short(call.id)} accepted on the phone`);
    sendJson(res, 200, { ok: true, test: Boolean(call.test) });
  }

  /**
   * The app's SIP registration succeeded while a pushed call rings.
   * Body: { call_id, call_key } for one call, or no call with the phone's
   * device token for every call ringing its endpoint. Replies per call:
   *   transferred  every pushed phone has reported: the caller's leg is
   *                transferred (Vobiz Transfer API) to /dial-now, which
   *                starts the Dial now instead of at the end of the wait;
   *   waiting      the Dial starts at the end of the wait (other pushed
   *                phones have not reported yet, the wait is about to end,
   *                or the transfer failed); this phone is in it;
   *   too_late     the Dial had already started without this phone. It is
   *                not restarted (that would cut off a ringing browser or
   *                PSTN leg); the app gets call_ended when the call ends;
   *   finished     the call is over;  test  a test call.
   */
  async function onRegistered(req, res) {
    const body = await readJson(req);
    let list;
    let device = null;
    if (body.call_id) {
      const call = callFor(body);
      if (!call) return sendJson(res, 404, { error: 'Unknown call' });
      list = [call];
    } else {
      device = deviceFromRequest(req);
      if (!device) return sendJson(res, 401, { error: 'Send call_id and call_key, or this phone\'s device token' });
      list = [...calls.values()].filter((c) => c.targets.includes(device.username));
    }
    const results = {};
    for (const call of list) {
      if (call.finished || call.test) {
        results[call.id] = call.finished ? 'finished' : 'test';
        continue;
      }
      results[call.id] = await registeredFor(call, device ? device.id : `report-${call.registered.size}`);
    }
    const single = body.call_id ? results[body.call_id] : undefined;
    sendJson(res, 200, {
      ok: true,
      ...(single ? { redial: single, finished: single === 'finished' } : { calls: results }),
    });
  }

  /** One phone reported "registered" for `call`. Returns the reply value. */
  async function registeredFor(call, reporter) {
    if (call.dialStarted) {
      call.lateRegistered = true;
      log('..', `Call ${short(call.id)}: an app signed in after the Dial started; the others keep ringing (not restarted)`);
      return 'too_late';
    }
    call.registered.add(reporter);
    if (call.transferred) return 'transferred';
    if (call.registered.size < call.pushedDevices) {
      log('..', `Call ${short(call.id)}: ${call.registered.size} of ${call.pushedDevices} phones signed in; waiting for the rest`);
      return 'waiting';
    }
    return dialNow(call);
  }

  /** Ends the wait early: transfers the caller's leg to /dial-now. */
  async function dialNow(call) {
    if (call.waitUntil - Date.now() < TRANSFER_MARGIN_MS) {
      log('..', `Call ${short(call.id)}: the app is signed in; the wait ends in under a second and dials then`);
      return 'waiting';
    }
    if (!config.authId) {
      log('..', `Call ${short(call.id)}: the app is signed in, but without VOBIZ_AUTH_ID the bridge cannot cut the wait short`);
      return 'waiting';
    }
    call.transferred = true;
    try {
      await vobizApi('POST', `/Call/${encodeURIComponent(call.id)}/`, {
        legs: 'aleg',
        aleg_url: `${publicBase()}/dial-now/${callRef(call.id)}`,
        aleg_method: 'POST',
      });
      log('ok', `Call ${short(call.id)}: the app is signed in; dialling everyone now`);
      return 'transferred';
    } catch (error) {
      call.transferred = false;
      log('!!', `Call ${short(call.id)}: could not transfer to dial now (${error.message}); dialling when the wait ends`);
      return 'waiting';
    }
  }

  /**
   * Starts the one Dial: requested by the hold XML's <Redirect> when the
   * wait ends, or after the transfer in dialNow().
   */
  async function onDialNow(req, res, url) {
    const id = callIdFromPath(url);
    const call = id ? calls.get(id) : null;
    if (call?.finished === 'declined') return sendXml(res, declinedXml());
    if (!call || call.finished) return sendXml(res, '<Hangup/>');
    if (call.dialStarted) {
      // Vobiz only asks again if the document running the Dial was replaced
      // (a transfer that crossed the Redirect): the Dial has to be resent.
      log('!!', `Call ${short(call.id)}: /dial-now requested again after the Dial started; dialling again`);
    }
    return sendXml(res, dialXml(call));
  }

  /** The user tapped Decline. Needs the call's own key from the push. */
  async function onDecline(req, res) {
    const body = await readJson(req);
    const call = callFor(body);
    if (!call) return sendJson(res, 404, { error: 'Unknown call' });
    // Closing the call screen of a call that has already ended reports a
    // Decline too: nothing to do.
    if (call.finished) return sendJson(res, 200, { ok: true, finished: true });
    call.declined = true;
    log('ok', `Call ${short(call.id)} declined on the phone`);
    let busy = 'next_attempt';
    if (!call.test) {
      finish(call, 'declined');
      endRinging(call, 'declined');
      // Act now rather than at the Dial result (the end of the wait, or
      // never while the other targets are still ringing).
      if (config.authId) {
        try {
          await vobizApi('POST', `/Call/${encodeURIComponent(call.id)}/`, {
            legs: 'aleg',
            aleg_url: `${publicBase()}/declined/${callRef(call.id)}`,
            aleg_method: 'POST',
          });
          busy = 'transferred';
        } catch (error) {
          log('!!', `Call ${short(call.id)}: could not transfer to busy (${error.message}); the next dial result hangs up`);
        }
      }
    }
    sendJson(res, 200, { ok: true, busy });
  }

  /** The caller's leg after Decline: hear busy, then a busy rejection. */
  async function onDeclinedXml(req, res) {
    return sendXml(res, declinedXml());
  }

  /**
   * Busy for a declined call. <Hangup reason="busy"> rejects the call
   * unbilled only while it is unanswered; once a <Dial> has answered the
   * caller's leg, Vobiz ends it as a normal hangup (docs: /xml/hangup). So the
   * caller first hears a busy tone: as early media (not billed) if the call is
   * still unanswered, as ordinary audio if it was answered.
   */
  function declinedXml() {
    return `  <PreAnswer><Play>${esc(publicBase())}/busy.wav</Play></PreAnswer>\n  <Hangup reason="busy"/>`;
  }

  function callFor(body) {
    const call = calls.get(String(body.call_id || ''));
    if (!call || !safeEqual(String(body.call_key || ''), call.key)) return null;
    return call;
  }

  // ── Push messages (Firebase Cloud Messaging HTTP v1) ─────────────────────────

  /**
   * The incoming-call push. The phone's clock may be off, so the time left is
   * sent as a duration (ttl_ms, from when the bridge sends it): the app
   * stops ringing ttl_ms after the push arrives, or after FCM's sent time
   * when it has one. expires_at is the bridge's clock and is kept only for
   * older app builds; do not compare it with the phone's clock.
   */
  function incomingPayload(call) {
    return {
      type: 'incoming_call',
      call_id: call.id,
      call_key: call.key,
      caller: call.from,
      callee: call.to,
      server: publicBase(),
      sent_at: String(Date.now()),
      ttl_ms: String(Math.max(0, call.deadline - Date.now())),
      // The user is already on a call: show call waiting, not the full-screen
      // ringing screen, and leave the active call's service alone.
      ...(call.lineBusy ? { line_busy: '1' } : {}),
      expires_at: String(call.deadline),
      ...(call.test ? { test: '1' } : {}),
    };
  }

  /** Tells the pushed phones to stop ringing. Does not hold up the reply to Vobiz. */
  function endRinging(call, reason) {
    if (call.endedPushSent) return;
    call.endedPushSent = true;
    background(pushToTargets(call, { type: 'call_ended', call_id: call.id, reason }), 'push');
  }

  function background(promise, label) {
    promise.catch((error) => log('!!', `${label} failed: ${error.message}`));
  }

  async function pushToTargets(call, data) {
    // FCM drops an incoming-call push that cannot arrive before the caller
    // gives up; "call ended" pushes only matter for a minute.
    const ttlSeconds = data.type === 'incoming_call'
      ? Math.max(1, Math.ceil((call.deadline - Date.now()) / 1000))
      : 60;
    const devices = devicesOf(call.targets).filter((d) => d.token && (!call.onlyDevice || d.id === call.onlyDevice));
    if (!devices.length) return;
    if (!firebase.ready && !deps.sendPush) {
      log('!!', 'Not sending a push: FIREBASE_SERVICE_ACCOUNT is not set up');
      return;
    }
    await Promise.all(devices.map(async (device) => {
      const result = await sendPush(device.token, data, { ttlSeconds });
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

  async function sendPush(token, data, opts = {}) {
    if (deps.sendPush) return deps.sendPush(token, data, opts);
    const { validateOnly = false, ttlSeconds = config.ringSeconds } = opts;
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
            android: { priority: 'HIGH', ttl: `${ttlSeconds}s` },
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
    for (const device of Object.values(state.devices)) {
      if (device.token === token) {
        log('..', `Removed an expired push token from ${device.username}; the app registers a new one when it next signs in`);
        // Keep the endpoint ringing even without a token.
        device.token = null;
      }
    }
    saveState();
  }

  // ── Vobiz: signatures, account set-up ────────────────────────────────────────

  /** Parses a Vobiz webhook and checks its signature and nonce (fails closed). */
  function vobiz(handler) {
    return async (req, res, url) => {
      const raw = await readBody(req);
      if (verifySignatures) {
        const verdict = checkSignature(req, url);
        if (verdict !== 'ok') {
          log('!!', `Rejected ${req.method} ${url.pathname}: ${verdict}`);
          return sendText(res, 403, 'Invalid signature');
        }
      }
      const params = Object.fromEntries(new URLSearchParams(url.search));
      const type = String(req.headers['content-type'] || '');
      if (type.includes('application/json')) {
        try { Object.assign(params, JSON.parse(raw || '{}')); } catch { /* ignore */ }
      } else if (raw) {
        Object.assign(params, Object.fromEntries(new URLSearchParams(raw)));
      }
      return handler(req, res, url, params);
    };
  }

  /**
   * Vobiz signs base64(HMAC-SHA256(authToken, baseUrl + "." + nonce)) (V3) or
   * baseUrl + nonce (V2), where baseUrl is the URL it called without the query
   * string (docs: /concepts/validating-callbacks). The body is not signed, so
   * everything that must be trusted (the call a Dial callback is about) is in
   * the path. A nonce is accepted once only.
   */
  function checkSignature(req, url) {
    const baseUrl = `${config.publicUrl}${url.pathname}`;
    const checks = [
      ['x-vobiz-signature-v3', 'x-vobiz-signature-v3-nonce', '.'],
      ['x-vobiz-signature-ma-v3', 'x-vobiz-signature-v3-nonce', '.'],
      ['x-vobiz-signature-v2', 'x-vobiz-signature-v2-nonce', ''],
      ['x-vobiz-signature-ma-v2', 'x-vobiz-signature-v2-nonce', ''],
    ];
    let sawSignature = false;
    for (const [sigHeader, nonceHeader, separator] of checks) {
      const signature = String(req.headers[sigHeader] || '');
      const nonce = String(req.headers[nonceHeader] || '');
      if (!signature || !nonce) continue;
      sawSignature = true;
      const expected = crypto.createHmac('sha256', config.authToken).update(baseUrl + separator + nonce).digest('base64');
      if (!safeEqual(signature, expected)) continue;
      if (!rememberNonce(nonce)) return 'nonce already used (replayed request)';
      return 'ok';
    }
    return sawSignature
      ? 'signature does not match (is PUBLIC_URL the exact address Vobiz calls, and VOBIZ_AUTH_TOKEN this account\'s token?)'
      : 'no X-Vobiz-Signature-V3 / -V2 headers (Vobiz only signs callback URLs that have credentials configured)';
  }

  /** Records a nonce; false when it was seen before inside NONCE_TTL_MS. */
  function rememberNonce(nonce) {
    pruneNonces();
    if (Object.prototype.hasOwnProperty.call(state.nonces, nonce)) return false;
    state.nonces[nonce] = Date.now() + NONCE_TTL_MS;
    saveState();
    return true;
  }

  function pruneNonces() {
    const now = Date.now();
    for (const [nonce, expires] of Object.entries(state.nonces)) if (expires < now) delete state.nonces[nonce];
  }

  /** `<call id>.<tag>`: the tag proves the bridge itself wrote this path. */
  function callRef(id) {
    return `${encodeURIComponent(id)}.${callTag(id)}`;
  }

  function callTag(id) {
    return crypto.createHmac('sha256', state.webhookSecret).update(`call:${id}`).digest('base64url').slice(0, 22);
  }

  /** The call id from /dial-result/<ref> or /dial-events/<ref>, or null if the tag is wrong. */
  function callIdFromPath(url) {
    const ref = url.pathname.split('/')[2] || '';
    const dot = ref.lastIndexOf('.');
    if (dot < 1) return null;
    let id;
    try { id = decodeURIComponent(ref.slice(0, dot)); } catch { return null; }
    return safeEqual(ref.slice(dot + 1), callTag(id)) ? id : null;
  }

  async function vobizApi(method, pathname, body) {
    if (deps.vobizApi) return deps.vobizApi(method, pathname, body);
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

  /**
   * Whether `username` is an endpoint on VOBIZ_AUTH_ID's account: true,
   * false, null when Vobiz could not be asked, undefined when there is no
   * account to ask.
   */
  async function endpointKnown(username) {
    if (!config.authId || !config.authToken) return undefined;
    try {
      if (!endpointCache.names || Date.now() - endpointCache.at > 60 * 1000) {
        const endpoints = await listAll('/Endpoint/');
        endpointCache.names = new Set(endpoints.filter((e) => e.username).map((e) => String(e.username).toLowerCase()));
        endpointCache.at = Date.now();
      }
      return endpointCache.names.has(username.toLowerCase());
    } catch (error) {
      log('!!', `Vobiz: could not list endpoints: ${error.message}`);
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

    log(verifySignatures ? 'ok' : '!!', verifySignatures
      ? 'Webhooks: Vobiz signatures (V3/V2) and nonces are checked'
      : 'Webhooks: signatures are NOT checked (ALLOW_UNSIGNED_WEBHOOKS=true). Anyone who finds this address can ring your phones. Local testing only.');

    const registered = Object.entries(state.devices)
      .map(([id, d]) => `${d.username} on ${id} (${d.token ? 'push' : 'no push'})`);
    log('..', `Phones registered: ${registered.length ? registered.join(', ') : 'none yet'}`);
    for (const [number, route] of config.routes) log('..', `Calls to ${number} ring ${[...route.users, ...route.numbers].join(', ')}`);
    log('..', `Inbound calls wait up to ${config.pushWaitSeconds} s for a pushed app to sign in, then ring for ${config.ringSeconds} s`);

    console.log('');
    if (keyIsNew) {
      // Shown once, when it is created. Afterwards it is in the state file
      // (readable by this user only) or in BRIDGE_KEY.
      console.log('  Pair a phone: Identity tab → Incoming calls → Push server, paste this line:');
      console.log('');
      console.log(`    ${config.publicUrl || 'https://<your-tunnel>'}#key=${state.bridgeKey}`);
    } else {
      console.log(`  Pair a phone with ${config.publicUrl || 'https://<your-tunnel>'}#key=<bridge key>; the key is bridgeKey in ${config.stateFile} (or BRIDGE_KEY).`);
    }
    console.log('');
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /** The registered phone whose device token is in `Authorization: Bearer`, or null. */
  function deviceFromRequest(req) {
    const match = String(req.headers.authorization || '').match(/^Bearer\s+([\w-]+)\.([\w-]+)$/);
    if (!match || !Object.prototype.hasOwnProperty.call(state.devices, match[1])) return null;
    const device = state.devices[match[1]];
    if (!device.secretHash || !safeEqual(sha256(match[2]), device.secretHash)) return null;
    return { id: match[1], ...device };
  }

  function keyMatches(req) {
    const header = String(req.headers['x-bridge-key'] || '');
    return Boolean(header) && safeEqual(header, state.bridgeKey);
  }







  function publicBase() {
    return config.publicUrl || `http://localhost:${config.port}`;
  }












  function loadState() {
    try {
      const json = JSON.parse(fs.readFileSync(config.stateFile, 'utf8'));
      const object = (v) => (v && typeof v === 'object' ? v : {});
      return {
        bridgeKey: json.bridgeKey || '',
        webhookSecret: json.webhookSecret || '',
        // { deviceId: { username, token, secretHash, … } }. Records from the
        // old { username: [devices] } layout had no per-phone secret: the
        // phones pair again.
        devices: Object.fromEntries(Object.entries(object(json.devices))
          .filter(([, d]) => d && !Array.isArray(d) && d.username && d.secretHash)),
        nonces: object(json.nonces),
      };
    } catch {
      return { bridgeKey: '', webhookSecret: '', devices: {}, nonces: {} };
    }
  }

  function saveState() {
    const tmp = `${config.stateFile}.tmp`;
    // The bridge key, device secrets' hashes and push tokens: this user only.
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
    fs.chmodSync(tmp, 0o600);
    fs.renameSync(tmp, config.stateFile);
  }

  return { server, config, state, calls, start, close, firebase, verifySignatures, ringTargets };
}

// ── Module helpers ───────────────────────────────────────────────────────────

/** Settings that would leave the webhooks open. Empty when it is safe to start. */
export function configProblems(config, env, allowUnsigned) {
  const problems = [];
  if (env.VERIFY_SIGNATURES === 'false') {
    problems.push('VERIFY_SIGNATURES=false is no longer supported; for local testing only, set ALLOW_UNSIGNED_WEBHOOKS=true');
  }
  if (allowUnsigned) return problems;
  if (!config.publicUrl) problems.push('PUBLIC_URL is not set: it is part of every Vobiz signature, so webhooks cannot be checked');
  else if (!/^https:\/\//i.test(config.publicUrl)) problems.push('PUBLIC_URL must be https:// (a signature sent over plain HTTP can be captured and replayed)');
  if (!config.authToken) problems.push('VOBIZ_AUTH_TOKEN is not set: it is the key Vobiz signs webhooks with');
  return problems;
}

/** A PSTN destination in ROUTES: `+` and 6 to 15 digits (E.164). */
const PSTN_RE = /^\+\d{6,15}$/;

/**
 * ROUTES=+919876543210=alice,bob,+919800000001;+918000000000=carol →
 * Map(number → { users: [endpoints], numbers: [PSTN numbers] }). An entry of
 * `+` and digits is a phone number rung with <Number>; anything else is an
 * endpoint username, as before.
 */
export function parseRoutes(value) {
  const routes = new Map();
  for (const entry of String(value || '').split(';')) {
    const [number, list] = entry.split('=');
    if (!number || !list) continue;
    const items = list.split(',').map((s) => s.trim()).filter(Boolean);
    const numbers = [...new Set(items.filter((s) => PSTN_RE.test(s)))];
    const users = csv(items.filter((s) => !PSTN_RE.test(s)).join(','));
    if (users.length || numbers.length) routes.set(displayNumber(number.trim()), { users, numbers });
  }
  return routes;
}

/** Ringback cadence bursts ([start, end] s) filling `seconds`: 0.4 on, 0.2 off, 0.4 on, 2 off. */
function ringbackBursts(seconds) {
  const bursts = [];
  for (let t = 0; t < seconds; t += 3) bursts.push([t, t + 0.4], [t + 0.6, t + 1.0]);
  return bursts;
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value)).digest('base64url');
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

function sendWav(res, wav) {
  res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': wav.length, 'Cache-Control': 'public, max-age=3600' });
  res.end(wav);
}

/**
 * `seconds` of an Indian call-progress tone (400 Hz modulated at 25 Hz),
 * sounding during `bursts` ([start, end] in seconds), as 8 kHz 16-bit mono
 * WAV. Ringback: see ringbackBursts(). Busy: 0.75 s on/off.
 */
function makeToneWav(seconds, bursts) {
  const rate = 8000;
  const samples = rate * seconds;
  const pcm = Buffer.alloc(samples * 2);
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

function defaultLog(tag, message) {
  const time = new Date().toTimeString().slice(0, 8);
  console.log(`[${time}] ${tag.padEnd(2)} ${message}`);
}

// Run as a program (not when imported by the tests).
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  loadEnvFile(path.join(HERE, '.env'));
  try {
    createBridge().start();
  } catch (error) {
    if (error.code !== 'BRIDGE_CONFIG') throw error;
    console.error(error.message);
    console.error('Fix .env (see .env.example) and start again. ALLOW_UNSIGNED_WEBHOOKS=true skips the check for local tests only.');
    process.exit(1);
  }
}
