#!/usr/bin/env node
/**
 * Sample server for the Flutter example app. It:
 *
 *   1. answers your Vobiz number and rings, at once and in ONE <Dial>, the
 *      SIP users and phone numbers ROUTES gives for the dialled number plus
 *      the ALWAYS_RING users. The first to answer wins; Vobiz cancels the
 *      rest. A closed app is woken by Vobiz push (Vobiz's registrar holds
 *      the call and pushes the phone), not by this server;
 *   2. mints access tokens (JWT) for the app with the account's Auth Token,
 *      which stays here;
 *   3. turns the app's call into a conference and manages it;
 *   4. watches the app's connection during a call, when the app reports;
 *   5. signs the phone up for Vobiz push with the account's credentials, so
 *      the phone never holds the Auth Token.
 *
 * Webhooks must carry a valid Vobiz signature (PUBLIC_URL and
 * VOBIZ_AUTH_TOKEN are required). The app sends the server's key
 * (X-Bridge-Key) and the SIP user it is signed in as (X-Bridge-User).
 * README.md has the app ↔ server protocol.
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
/** An access token's `sub`, as the platform accepts it (letters, digits, _ and -, at most 50). */
const SUB_RE = /^[A-Za-z0-9_-]{1,50}$/;
const CALL_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Builds a bridge without starting it. `options.env` replaces process.env,
 * `options.stateFile` the state file, and `options.deps` lets tests swap the
 * outside world: `vobizApi(method, path, body)` for the Vobiz REST API,
 * `fetch(url, init)` for the requests the server sends itself (device
 * sign-up), `log(tag, message)`.
 */
export function createBridge(options = {}) {
  const env = options.env || process.env;
  const deps = options.deps || {};
  const log = deps.log || defaultLog;
  const fetchFn = deps.fetch || fetch;
  const config = {
    port: clampInt(env.PORT, 8787, 1, 65535),
    publicUrl: (env.PUBLIC_URL || '').trim().replace(/\/+$/, ''),
    vobizApi: (env.VOBIZ_API_URL || 'https://api.vobiz.ai').trim().replace(/\/+$/, ''),
    authId: (env.VOBIZ_AUTH_ID || '').trim(),
    authToken: (env.VOBIZ_AUTH_TOKEN || '').trim(),
    number: (env.VOBIZ_NUMBER || '').trim(),
    appName: (env.VOBIZ_APP_NAME || 'Vobiz_Flutter_Push_Bridge').trim(),
    forceAttach: env.FORCE_ATTACH === 'true',
    ringSeconds: clampInt(env.RING_SECONDS, 45, 15, 120),
    // Connection watch (see onCallAlive): after this long without word from
    // the app during a call, the other party hears the connection-lost beep.
    lostBeepSeconds: clampInt(env.LOST_BEEP_SECONDS, 3, 2, 10),
    // ...and after this long the call is ended: the SDK gives up at 12 s, but
    // its hangup cannot leave an offline phone. 0 never ends it.
    lostHangupSeconds: env.LOST_HANGUP_SECONDS === '0' ? 0 : clampInt(env.LOST_HANGUP_SECONDS, 15, 5, 300),
    // A conference ends with its host, as a phone call does when one side
    // drops: this long after the app's last report the whole room is ended.
    confHostLostSeconds: clampInt(env.CONF_HOST_LOST_SECONDS, 2, 1, 300),
    // Access tokens (POST /token): who the app signs in as ("<sub>_<auth id>"),
    // for how long (180 s to 24 h, the platform's limits), and which
    // application's Answer URL handles its outbound calls (else the account's
    // default application).
    jwtSub: (env.JWT_SUB || 'flutter-app').trim(),
    jwtTtlSeconds: clampInt(env.JWT_TTL_SECONDS, 3600, 180, 86400),
    jwtAppId: (env.JWT_APP_ID || '').trim(),
    // The other subs /token may mint (besides JWT_SUB). Empty: any sub, for
    // anyone with the bridge key.
    jwtAllowedSubs: String(env.JWT_ALLOWED_SUBS || '').split(',').map((s) => s.trim()).filter((s) => SUB_RE.test(s)),
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
   * How long a webhook's nonces and signatures are remembered. Vobiz nonces
   * are random, not time-based, and nothing in the request is timestamped,
   * so replay protection is "never accept the same nonce or signature twice"
   * within this window. At most MAX_SEEN are kept (the soonest to expire go
   * first): the state file holds them and is written on every webhook.
   */
  const NONCE_TTL_MS = 24 * 60 * 60 * 1000;
  const MAX_SEEN = 10000;
  const INSTANCE = crypto.randomBytes(6).toString('hex');

  // ── State: the app's key, the webhook secret and seen nonces, kept across restarts ──

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
  // Indian busy tone: 400 Hz, 0.75 s on, 0.75 s off.
  const busyTone = makeToneWav(3, [[0, 0.75], [1.5, 2.25]]);
  // Connection-lost beep, looped: a short 1 kHz beep every 2.5 s.
  const lostBeep = makeToneWav(2.5, [[0, 0.25]], [1000]);
  // Hold music for a conference participant, looped by <Play loop="0">.
  const holdMusic = makeHoldMusicWav();

  // ── HTTP server ──────────────────────────────────────────────────────────────

  const routes = {
    'GET /': (req, res) => sendText(res, 200, 'Vobiz push bridge is running.\n'),
    'GET /health': (req, res) => sendJson(res, 200, { ok: true, service: 'vobiz-push-bridge', instance: INSTANCE }),
    'GET /busy.wav': (req, res) => sendWav(res, busyTone),
    'GET /lost.wav': (req, res) => sendWav(res, lostBeep),
    'GET /hold.wav': (req, res) => sendWav(res, holdMusic),
    // Vobiz webhooks
    'POST /answer': vobiz(onAnswer),
    'GET /answer': vobiz(onAnswer),
    // Per call: /dial-result/<call id>.<tag>, so the signed URL names the call
    'POST /dial-result/*': vobiz(onDialResult),
    'POST /dial-events/*': vobiz(onDialEvent),
    'POST /hangup': vobiz(onHangup),
    'GET /hangup': vobiz(onHangup),
    // The app
    'POST /token': onToken,
    // Vobiz push: the SDK's VobizPushDevices, pointed at this server
    'POST /push/devices/register': onDeviceRegister,
    'DELETE /push/devices/logout': onDeviceLogout,
    // During a call: the app reports it still has its network
    'POST /call/alive': onCallAlive,
    'POST /call/ended': onCallEnded,
    // DTMF test: the answer URL for a call placed through the Vobiz API
    'POST /dtmf-test': vobiz(onDtmfTest),
    'POST /dtmf-test-digits': vobiz(onDtmfTestDigits),
    // Conference: the app turns its call into a conference and manages it
    'POST /conference/add': onConferenceAdd,
    'POST /conference/state': onConferenceState,
    'POST /conference/participant': onConferenceParticipant,
    'POST /conference/end': onConferenceEnd,
    // Conference: Vobiz asks for a leg's XML and reports enter, exit and
    // hangup. The room and the leg's role are in the signed path.
    'POST /conf-room/*': vobiz(onConfRoom),
    'GET /conf-room/*': vobiz(onConfRoom),
    'POST /conf-hold/*': vobiz(onConfHold),
    'GET /conf-hold/*': vobiz(onConfHold),
    'POST /conf-events/*': vobiz(onConfEvents),
    'POST /conf-dial/*': vobiz(onConfDialEnded),
  };

  const server = http.createServer(async (req, res) => {
    // A target that is not a URL ("//", "http://[") throws here; outside a
    // try, one such request would stop the whole server.
    let url;
    try {
      url = new URL(req.url || '/', 'http://localhost');
    } catch {
      return sendJson(res, 400, { error: 'Bad request' });
    }
    const prefix = url.pathname.split('/').slice(0, 2).join('/');
    const handler = routes[`${req.method} ${url.pathname}`]
      || (url.pathname.split('/').length === 3 && routes[`${req.method} ${prefix}/*`]);
    if (!handler) return sendJson(res, 404, { error: 'Not found' });
    try {
      await handler(req, res, url);
    } catch (error) {
      log('!!', `${req.method} ${url.pathname} failed: ${error.stack || error}`);
      if (!res.headersSent) {
        if (url.pathname === '/answer' || /^\/(dial-result|conf-room|conf-hold)\//.test(url.pathname)) {
          sendXml(res, '<Speak>Sorry, something went wrong. Please try again.</Speak><Hangup/>');
        } else {
          sendJson(res, 500, { error: 'Internal error' });
        }
      }
    }
  });

  let sweeper = null;
  let watchdog = null;

  /**
   * Forgets old calls and rooms (every minute). A call is kept while it is
   * answered and not over (the conference and the connection watch need it),
   * otherwise 10 minutes. A room is kept 10 minutes after it ends (the app
   * reads its last state). Both are dropped after 5 hours however they
   * ended: the Dial's timeLimit is 4 hours.
   */
  function sweep(now = Date.now()) {
    const cutoff = now - 10 * 60 * 1000;
    const limit = now - 5 * 60 * 60 * 1000;
    for (const [id, call] of calls) {
      const live = call.bridged && !call.over;
      if (call.createdAt < limit || (call.createdAt < cutoff && !live)) calls.delete(id);
    }
    for (const room of rooms.values()) {
      if ((room.over && room.endedAt < cutoff) || room.createdAt < limit) forgetRoom(room);
    }
  }

  /** Starts listening. `port` 0 picks a free port (tests). Resolves with the port. */
  function start({ port = config.port, checks = true } = {}) {
    sweeper = setInterval(() => sweep(), 60 * 1000);
    sweeper.unref();
    watchdog = setInterval(checkWatched, deps.watchTickMs ?? 500);
    watchdog.unref();
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
    if (watchdog) clearInterval(watchdog);
    return new Promise((resolve) => server.close(() => resolve()));
  }

  // ── Vobiz webhooks ───────────────────────────────────────────────────────────

  /** Inbound call: ring everyone at once in one <Dial>. */
  async function onAnswer(req, res, url, params) {
    if (isHangupEvent(params)) return onHangup(req, res, url, params);

    const id = params.CallUUID || params.CallUuid || crypto.randomUUID();
    let call = calls.get(id);
    if (call) {
      log('..', `Vobiz asked again for call ${short(id)}`);
      return sendXml(res, dialXml(call));
    }

    const { users: targets, numbers } = ringTargets(params.To);
    if (!targets.length && !numbers.length) {
      log('..', `Inbound call from ${params.From || 'unknown'} to ${params.To || 'unknown'}: no ROUTES entry for that number and no ALWAYS_RING, so the caller is told`);
      return sendXml(res, '<Speak>Sorry, nobody is available to take this call. Please try again later.</Speak><Hangup/>');
    }

    call = {
      id,
      from: displayNumber(params.From),
      to: displayNumber(params.To),
      targets,
      numbers,
      createdAt: Date.now(),
      bridged: false,
      // The SIP user among `targets` whose leg answered, once Vobiz says.
      answeredBy: null,
      finished: null,
      // Every endpoint rung is already on a call this server connected.
      lineBusy: targets.length > 0 && targets.every((user) => onCall(user)),
      over: false,
    };
    calls.set(id, call);
    const everyone = [...targets, ...numbers].join(', ');
    log('->', `Inbound call ${short(id)} from ${call.from} to ${call.to}; will ring ${everyone}`);
    return sendXml(res, dialXml(call));
  }

  /** The single Dial attempt has ended: the call is answered, or it is over. */
  async function onDialResult(req, res, url, params) {
    const id = callIdFromPath(url);
    const call = id ? calls.get(id) : null;
    const status = String(params.DialStatus || '').toLowerCase();
    const cause = params.DialHangupCause || params.DialBLegHangupCause || '';
    if (!call) return sendXml(res, '<Hangup/>');
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
    // Every endpoint rung is on another call this server connected, so
    // "busy" is the app's SIP stack refusing a second call. Any other busy
    // is not proof that someone declined: Vobiz also reports busy for a SIP
    // user it could not reach.
    if (status === 'busy' && call.lineBusy) {
      finish(call, 'busy');
      return sendXml(res, busyXml());
    }
    if (status === 'cancel') {
      finish(call, 'caller hung up');
      return sendXml(res, '<Hangup/>');
    }
    // One Dial only: nobody answered (or every leg failed). No second attempt,
    // so a target that rang is never rung again from the start.
    finish(call, 'missed');
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
          // Only a user this call rang counts: a phone number, or a name in a
          // form this server did not write, leaves every target allowed.
          call.answeredBy = call.targets.find((user) => sameUser(user, by)) || null;
          finish(call, 'answered');
        }
      } else if (action === 'hangup' || event === 'DialHangup') {
        const cause = params.DialBLegHangupCauseName || params.DialBLegHangupCause || '';
        log('..', `Call ${short(call.id)}: ringing the app ended${cause ? ` (${cause})` : ''}`);
      }
    }
    sendText(res, 200, 'OK');
  }

  /** The caller's leg has ended. */
  async function onHangup(req, res, url, params) {
    const call = calls.get(params.CallUUID);
    if (call) {
      call.over = true;
      if (!call.finished) finish(call, `ended (${params.HangupCause || params.CallStatus || 'hangup'})`);
    }
    sendText(res, 200, 'OK');
  }

  /**
   * The one Dial: every routed SIP user, every ALWAYS_RING user and the
   * route's PSTN numbers, all at once. The first to answer wins. A user whose
   * app is closed rings when Vobiz push wakes it (Vobiz holds that leg while
   * it does); a user with no registration fails its leg at once.
   */
  function dialXml(call) {
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
   * Busy, for a Dial that ended busy because everyone rung is on a call.
   * <Hangup reason="busy"> rejects the call unbilled only while it is
   * unanswered; once a <Dial> has answered the caller's leg, Vobiz ends it as
   * a normal hangup (docs: /xml/hangup). So the caller first hears a busy
   * tone: as early media (not billed) if the call is still unanswered, as
   * ordinary audio if it was answered.
   */
  function busyXml() {
    return `  <PreAnswer><Play>${esc(publicBase())}/busy.wav</Play></PreAnswer>\n  <Hangup reason="busy"/>`;
  }

  /**
   * Metadata on the SIP INVITE of every <User>. PushRef is this call's
   * CallUUID (the caller's leg), which the app sends back as call_uuid to
   * /conference/* and /call/alive; Caller is the real caller's number (with
   * CALLER_ID_MODE=number every call shows the same number). Vobiz's docs
   * disagree on the key format ("RefX-VH=" on the SIP headers page, "Ref=" in
   * the Dial examples), so it is configurable.
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

  /**
   * Who rings for an inbound call to `to`: `users`, the SIP users ROUTES
   * maps that number to plus ALWAYS_RING, and `numbers`, the route's PSTN
   * numbers. The server does not know which phones are signed in, so with
   * neither setting nobody is rung.
   */
  function ringTargets(to) {
    const names = new Set();
    const route = config.routes.get(displayNumber(to));
    for (const user of route?.users || []) names.add(user);
    for (const user of config.alwaysRing) names.add(user);
    return { users: [...names], numbers: route?.numbers || [] };
  }

  /** Whether `user` is on a call this server connected and that has not ended. */
  function onCall(user) {
    for (const c of calls.values()) if (c.bridged && !c.over && isCallOf(c, user)) return true;
    return false;
  }

  /**
   * Whether inbound `call` is `user`'s: the user who answered it, once Vobiz
   * has named one of the users rung; until then, any user it rings.
   */
  function isCallOf(call, user) {
    if (!user) return false;
    return call.answeredBy ? sameUser(call.answeredBy, user) : call.targets.some((target) => sameUser(target, user));
  }

  // ── The app's requests ───────────────────────────────────────────────────────

  /**
   * Who an app request is from, or null after answering it with the refusal.
   * The request must carry the bridge key (X-Bridge-Key). X-Bridge-User names
   * the SIP user the app is signed in as: `{ username }`. Without that header
   * the request is the key holder's own (`{ username: null, operator: true }`),
   * unless `needUser`. A header that is present but empty or not a user name
   * is refused (400), never read as the key holder. The user name is what the
   * app says it is: it picks the app's leg of a call, it does not prove who
   * is asking.
   */
  function appCaller(req, res, { needUser = false } = {}) {
    if (!keyMatches(req)) {
      sendJson(res, 401, { error: needUser ? 'Send the bridge key and X-Bridge-User' : 'Send the bridge key' });
      return null;
    }
    const header = req.headers['x-bridge-user'];
    if (header === undefined) {
      if (!needUser) return { username: null, operator: true };
      sendJson(res, 401, { error: 'Send X-Bridge-User: the SIP user the app is signed in as' });
      return null;
    }
    const username = String(header).trim();
    if (!USERNAME_RE.test(username)) {
      sendJson(res, 400, { error: 'X-Bridge-User must be the SIP user name the app is signed in as' });
      return null;
    }
    return { username, operator: false };
  }

  let jwtAppWarned = false;

  /**
   * An access token (JWT) for the app: `POST /Account/{auth id}/JWT/Token/`
   * mints it with the account's Auth Token, which stays here. The app signs
   * in with it (the SDK's connectWithAccessTokenProvider) as
   * "<sub>_<auth id>", and the token renews itself through this route before
   * it expires. Anyone with the bridge key may ask; `sub` comes from the body
   * or ?sub=, else JWT_SUB. With JWT_ALLOWED_SUBS set, only those subs and
   * JWT_SUB are minted; without it, any sub is (a key holder can then sign in
   * as any user). Same reply shape as the Vobiz WebRTC demo's /token.
   */
  async function onToken(req, res, url) {
    if (!appCaller(req, res)) return;
    if (!config.authId || !config.authToken) return sendJson(res, 503, { error: 'VOBIZ_AUTH_ID and VOBIZ_AUTH_TOKEN are not set' });
    const body = await readJson(req);
    const sub = String(body.sub || url.searchParams.get('sub') || config.jwtSub).trim();
    if (!SUB_RE.test(sub)) return sendJson(res, 400, { error: 'sub must be 1 to 50 letters, digits, _ or -' });
    if (config.jwtAllowedSubs.length && sub !== config.jwtSub && !config.jwtAllowedSubs.includes(sub)) {
      log('!!', `Refused an access token for ${sub}: not in JWT_ALLOWED_SUBS`);
      return sendJson(res, 403, { error: `This server does not mint tokens for ${sub}` });
    }
    // nbf a minute in the past: a registrar whose clock is a second behind
    // this one refuses a token whose nbf has not come yet (10005). The
    // platform's 180 s to 24 h limits apply to exp - nbf.
    const nbf = Math.floor(Date.now() / 1000) - 60;
    const claims = {
      iss: config.authId,
      sub,
      nbf,
      exp: nbf + config.jwtTtlSeconds,
      per: { voice: { incoming_allow: true, outgoing_allow: true } },
      ...(config.jwtAppId ? { app: config.jwtAppId } : {}),
    };
    if (!config.jwtAppId && !jwtAppWarned) {
      jwtAppWarned = true;
      log('!!', 'JWT_APP_ID is not set: tokens carry no app, so the account\'s default application handles outbound calls, and where that does not work the registrar refuses the token (10001 INVALID_ACCESS_TOKEN). Set JWT_APP_ID.');
    }
    let minted;
    try {
      minted = await vobizApi('POST', '/JWT/Token/', claims);
    } catch (error) {
      log('!!', `Vobiz: could not mint an access token for ${sub}: ${error.message}`);
      return sendJson(res, 502, { error: 'Vobiz did not mint the token' });
    }
    if (typeof minted?.token !== 'string' || !minted.token) return sendJson(res, 502, { error: 'Vobiz returned no token' });
    const sipUsername = `${sub}_${config.authId}`;
    const reason = typeof body.reason === 'string' ? ` (${body.reason.slice(0, 20)})` : '';
    log('ok', `Access token for ${sipUsername}, valid until ${new Date(claims.exp * 1000).toISOString()}${reason}`);
    sendJson(res, 200, { token: minted.token, sub, exp: claims.exp, sip_username: sipUsername });
  }

  // ── Vobiz push: the app signs its phone up through this server ───────────────
  //
  // Vobiz pushes a call for a SIP user to the devices registered for that
  // user. The SDK's VobizPushDevices, pointed at this server (pathPrefix
  // '/push/devices'), sends the body Vobiz takes. The server checks that the
  // phone signs up for the SIP user the app says it is, and that this user is
  // one of the account's; it then sends the request on with the account's
  // credentials, which never reach the phone, and relays Vobiz's answer.

  /** The fields of VobizPushDevices.register's body, and their longest length. */
  const DEVICE_FIELDS = {
    device_id: 200,
    push_token: 4096,
    platform: 20,
    push_type: 20,
    app_bundle_id: 200,
    app_version: 100,
    sdk_version: 100,
    sip_username: 120,
  };

  async function onDeviceRegister(req, res) {
    const who = appCaller(req, res, { needUser: true });
    if (!who) return;
    if (!config.authId || !config.authToken) return sendJson(res, 503, { error: 'VOBIZ_AUTH_ID and VOBIZ_AUTH_TOKEN are not set' });
    const body = await readJson(req);
    const device = {};
    for (const [field, max] of Object.entries(DEVICE_FIELDS)) {
      const value = body[field];
      if (value === undefined || value === null) continue;
      if (typeof value !== 'string' || value.length > max) return sendJson(res, 400, { error: `${field} must be a string of at most ${max} characters` });
      device[field] = value.trim();
    }
    if (!device.device_id || !device.push_token || !device.sip_username) {
      return sendJson(res, 400, { error: 'device_id, push_token and sip_username are required' });
    }
    if (device.sip_username !== who.username) {
      return sendJson(res, 403, { error: 'sip_username must be the SIP user in X-Bridge-User' });
    }
    const known = await sipUserKnown(who.username);
    if (known === null) return sendJson(res, 503, { error: 'Could not check the SIP user with Vobiz; try again' });
    if (!known) {
      log('!!', `Push: refused to sign up a device for ${who.username}: not a SIP user of ${config.authId}`);
      return sendJson(res, 403, { error: `${who.username} is not an endpoint or access-token user of this account` });
    }
    // Whatever the app sent: the device belongs to this server's account.
    device.auth_id = config.authId;
    const reply = await forwardToVobiz('POST', '/api/v1/devices/register', device, [device.push_token]);
    if (reply.status >= 200 && reply.status < 300) {
      log('ok', `Push: device ${short(device.device_id)} signed up for ${who.username}`);
    } else {
      log('!!', `Push: Vobiz refused to sign up device ${short(device.device_id)} for ${who.username} (${reply.status}${vobizReason(reply.body)})`);
    }
    sendJson(res, reply.status, reply.body);
  }

  async function onDeviceLogout(req, res) {
    if (!appCaller(req, res)) return;
    if (!config.authId || !config.authToken) return sendJson(res, 503, { error: 'VOBIZ_AUTH_ID and VOBIZ_AUTH_TOKEN are not set' });
    const body = await readJson(req);
    const deviceId = typeof body.device_id === 'string' ? body.device_id.trim() : '';
    if (!deviceId || deviceId.length > DEVICE_FIELDS.device_id) return sendJson(res, 400, { error: 'device_id is required' });
    const reply = await forwardToVobiz('DELETE', '/api/v1/devices/logout', { device_id: deviceId });
    // Vobiz's reason is not logged: it could quote the device's push token,
    // which this request does not carry, so it cannot be blanked out.
    if (reply.status >= 200 && reply.status < 300) {
      log('ok', `Push: device ${short(deviceId)} signed out`);
    } else {
      log('!!', `Push: Vobiz refused to sign out device ${short(deviceId)} (${reply.status})`);
    }
    sendJson(res, reply.status, reply.body);
  }

  /**
   * Sends `body` to the Vobiz API at `pathname` with the account's
   * credentials. Returns what to relay: Vobiz's status and JSON reply, with
   * the Auth Token, the bridge key and every value in `hide` (push tokens)
   * blanked out wherever they appear. Never throws: no answer is a 502.
   */
  async function forwardToVobiz(method, pathname, body, hide = []) {
    let response;
    let text;
    try {
      response = await fetchFn(`${config.vobizApi}${pathname}`, {
        method,
        headers: { 'X-Auth-ID': config.authId, 'X-Auth-Token': config.authToken, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      });
      text = await response.text();
    } catch (error) {
      log('!!', `Vobiz: ${method} ${pathname} failed: ${error.name === 'TimeoutError' ? 'no answer in 15 s' : error.message}`);
      return { status: 502, body: { error: 'Vobiz could not be reached' } };
    }
    let json;
    try { json = text ? JSON.parse(text) : {}; } catch { json = { error: text.slice(0, 200) }; }
    if (!json || typeof json !== 'object') json = { value: json };
    const secrets = [config.authToken, state.bridgeKey, ...hide].filter((s) => s && s.length >= 8);
    return { status: response.status, body: hideSecrets(json, secrets) };
  }

  const endpointCache = { at: 0, names: null };

  /** An access-token identity on this account: "<sub>_<auth id>" (see /token). */
  function isTokenIdentity(username) {
    const suffix = `_${config.authId}`.toLowerCase();
    const name = String(username || '').toLowerCase();
    return Boolean(config.authId) && name.length > suffix.length && name.endsWith(suffix)
      && SUB_RE.test(name.slice(0, -suffix.length));
  }

  /**
   * Whether `username` is a SIP user of VOBIZ_AUTH_ID's account: an endpoint,
   * or an access-token identity "<sub>_<auth id>" (an identity the token
   * creates, not a Console endpoint). null when Vobiz could not be asked.
   */
  async function sipUserKnown(username) {
    if (isTokenIdentity(username)) return true;
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
   * the path. A nonce, and a signature, is accepted once only: a V3
   * signature for nonce N is also a valid V2 signature for nonce ".N".
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
      // Every nonce and signature the request carries, so that no part of it
      // can be sent again in another form.
      const parts = new Set();
      for (const [sig, non] of checks) {
        if (req.headers[sig]) parts.add(`sig:${req.headers[sig]}`);
        if (req.headers[non]) parts.add(String(req.headers[non]));
      }
      if (!rememberSeen([...parts])) return 'nonce or signature already used (replayed request)';
      return 'ok';
    }
    return sawSignature
      ? 'signature does not match (is PUBLIC_URL the exact address Vobiz calls, and VOBIZ_AUTH_TOKEN this account\'s token?)'
      : 'no X-Vobiz-Signature-V3 / -V2 headers (Vobiz only signs callback URLs that have credentials configured)';
  }

  /** Records a request's nonces and signatures; false when one was seen before inside NONCE_TTL_MS. */
  function rememberSeen(parts) {
    pruneNonces();
    if (parts.some((part) => Object.prototype.hasOwnProperty.call(state.nonces, part))) return false;
    const expires = Date.now() + NONCE_TTL_MS;
    for (const part of parts) state.nonces[part] = expires;
    pruneNonces();
    try {
      saveState();
    } catch (error) {
      // The request is genuine and is remembered in memory, so the call goes
      // on; only a restart would forget it.
      log('!!', `Could not save ${config.stateFile}: ${error.message}`);
    }
    return true;
  }

  function pruneNonces() {
    const now = Date.now();
    for (const [nonce, expires] of Object.entries(state.nonces)) if (expires < now) delete state.nonces[nonce];
    const entries = Object.entries(state.nonces);
    if (entries.length > MAX_SEEN) {
      entries.sort((a, b) => a[1] - b[1]);
      for (const [nonce] of entries.slice(0, entries.length - MAX_SEEN)) delete state.nonces[nonce];
    }
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

  /**
   * Every object of a paged Vobiz list (`?limit=&offset=`). Vobiz returns at
   * most 20 a page whatever the limit, so the next page starts after what
   * came back: stepping by the limit skipped objects, and missed this
   * bridge's own application on an account with more than 20.
   */
  async function listAll(collection) {
    const all = [];
    for (let offset = 0; offset < 5000;) {
      const page = await vobizApi('GET', `${collection}?limit=100&offset=${offset}`);
      const objects = page?.objects || [];
      all.push(...objects);
      offset += objects.length;
      const total = page?.meta?.total_count ?? 0;
      if (!objects.length || offset >= total) break;
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

  // ── Start-up checks ──────────────────────────────────────────────────────────

  async function startupChecks() {
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

    for (const [number, route] of config.routes) log('..', `Calls to ${number} ring ${[...route.users, ...route.numbers].join(', ')}`);
    if (config.alwaysRing.length) log('..', `Every inbound call also rings ${config.alwaysRing.join(', ')}`);
    if (!config.routes.size && !config.alwaysRing.length) {
      log('!!', 'ROUTES and ALWAYS_RING are empty: inbound calls ring nobody. Set ROUTES=<your number>=<SIP user> in .env.');
    }
    log('..', `Inbound calls ring for ${config.ringSeconds} s`);
    if (config.jwtAllowedSubs.length) {
      log('ok', `Access tokens: only for ${[config.jwtSub, ...config.jwtAllowedSubs].join(', ')}`);
    } else {
      log('!!', 'Access tokens: /token mints a token for any sub to anyone with the bridge key. Set JWT_ALLOWED_SUBS to limit it.');
    }

    console.log('');
    if (keyIsNew) {
      // Shown once, when it is created. Afterwards it is in the state file
      // (readable by this user only, on Linux and macOS) or in BRIDGE_KEY.
      console.log('  Connect the app: Identity tab → Sample server, paste this line:');
      console.log('');
      console.log(`    ${config.publicUrl || 'https://<your-tunnel>'}#key=${state.bridgeKey}`);
    } else {
      console.log(`  Connect the app with ${config.publicUrl || 'https://<your-tunnel>'}#key=<bridge key>; the key is bridgeKey in ${config.stateFile} (or BRIDGE_KEY).`);
    }
    console.log('');
  }

  // ── Connection watch: the other party hears when the app's network drops ─────
  //
  // A phone that loses its network cannot tell anyone, so during a call the app
  // reports "alive" every second. When the reports stop for LOST_BEEP_SECONDS,
  // the bridge, still online, has Vobiz play a short beep to the other party
  // every 2.5 s, and stops it when the app is back. The SDK gives a dropped call
  // 12 s to come back; after LOST_HANGUP_SECONDS without a report it has given
  // up, but its BYE could not leave the offline phone, and Vobiz would keep the
  // call up (and billed) for about five minutes. So the bridge ends it. The
  // app reports with the bridge key and its SIP user (X-Bridge-User).

  /** Calls being watched, by the CallUUID the app reports. Memory only. */
  const watched = new Map();
  /** Ownership checks in flight, so a call's first reports look it up once. */
  const watchLookups = new Map();
  const lostBeepMs = deps.lostBeepMs ?? config.lostBeepSeconds * 1000;
  const lostHangupMs = deps.lostHangupMs ?? config.lostHangupSeconds * 1000;
  const confHostLostMs = deps.confHostLostMs ?? config.confHostLostSeconds * 1000;

  async function onCallAlive(req, res) {
    const who = appCaller(req, res, { needUser: true });
    if (!who) return;
    const body = await readJson(req);
    const uuid = String(body.call_uuid || '').toLowerCase();
    if (!CALL_UUID_RE.test(uuid)) return sendJson(res, 400, { error: 'call_uuid must be a Vobiz CallUUID' });
    let watch = watched.get(uuid);
    if (!watch) {
      const key = `${uuid} ${who.username}`;
      if (!watchLookups.has(key)) {
        watchLookups.set(key, otherPartyLeg(uuid, who.username).finally(() => watchLookups.delete(key)));
      }
      const legs = await watchLookups.get(key);
      if (!legs) return sendJson(res, 403, { error: 'Not a live call of this SIP user' });
      watch = watched.get(uuid);
      if (!watch) {
        watch = { uuid, username: who.username, legs, lastSeen: Date.now(), beeping: false, beepFailed: false, busy: false };
        watched.set(uuid, watch);
        log('..', `Call ${short(uuid)}: watching ${who.username}'s connection (beeps go to the ${legs === 'aleg' ? 'caller' : 'callee'})`);
      }
    }
    if (watch.username !== who.username) return sendJson(res, 403, { error: 'Not a call of this SIP user' });
    watch.lastSeen = Date.now();
    watch.beepFailed = false;
    if (watch.beeping && !watch.busy) await stopBeep(watch, 'the app is back');
    sendJson(res, 200, { ok: true });
  }

  /** The call ended in the app: stop watching it. */
  async function onCallEnded(req, res) {
    const who = appCaller(req, res, { needUser: true });
    if (!who) return;
    const body = await readJson(req);
    const watch = watched.get(String(body.call_uuid || '').toLowerCase());
    if (watch && watch.username === who.username) forget(watch, 'ended in the app');
    sendJson(res, 200, { ok: true });
  }

  /**
   * Which leg of call `uuid` is the app's other party, as Vobiz's Play API
   * names it ('aleg' or 'bleg'), or null when the call is not live or is not
   * this SIP user's: an app can only make the bridge act on its own calls.
   */
  async function otherPartyLeg(uuid, username) {
    // An inbound call this bridge rang: its UUID is the caller's own leg.
    const own = calls.get(uuid);
    if (own && !own.over && isCallOf(own, username)) return 'aleg';
    let live;
    try {
      live = await vobizApi('GET', `/Call/${encodeURIComponent(uuid)}/?status=live`);
    } catch {
      return null;
    }
    // The app's own leg (it placed or took the call): the other party is the
    // leg bridged to it.
    return [live?.from, live?.to].some((end) => endpointUsername(end) === username) ? 'bleg' : null;
  }

  function checkWatched() {
    const now = Date.now();
    for (const watch of watched.values()) {
      if (watch.busy) continue;
      const silent = now - watch.lastSeen;
      // The app hosts a conference: the room ends CONF_HOST_LOST_SECONDS after
      // its last report, not after the one-to-one call's reconnect window.
      const hangupMs = activeRoomOf(watch.uuid) ? confHostLostMs : lostHangupMs;
      if (hangupMs && silent >= hangupMs) void endLostCall(watch, silent);
      else if (silent >= lostBeepMs && !watch.beeping && !watch.beepFailed) void startBeep(watch, silent);
    }
  }

  async function startBeep(watch, silent) {
    // In a conference the call's legs are no longer bridged to each other, so
    // there is no "other party" leg to beep to. The room carries on.
    if (activeRoomOf(watch.uuid)) {
      watch.beepFailed = true;
      return;
    }
    watch.busy = true;
    try {
      await vobizApi('POST', `/Call/${encodeURIComponent(watch.uuid)}/Play/`, {
        urls: `${publicBase()}/lost.wav`,
        legs: watch.legs,
        loop: true,
        mix: true,
      });
      watch.beeping = true;
      log('..', `Call ${short(watch.uuid)}: no word from the app for ${secs(silent)} s; the other party hears the connection-lost beep`);
    } catch (error) {
      if (isGone(error)) return forget(watch, 'the call is over');
      // Not retried until the app reports again.
      watch.beepFailed = true;
      log('!!', `Call ${short(watch.uuid)}: could not play the beep: ${error.message}`);
    } finally {
      watch.busy = false;
    }
  }

  async function stopBeep(watch, why) {
    watch.busy = true;
    watch.beeping = false;
    try {
      await vobizApi('DELETE', `/Call/${encodeURIComponent(watch.uuid)}/Play/`);
      log('ok', `Call ${short(watch.uuid)}: ${why}; beep stopped`);
    } catch (error) {
      if (isGone(error)) forget(watch, 'the call is over');
      else log('!!', `Call ${short(watch.uuid)}: could not stop the beep: ${error.message}`);
    } finally {
      watch.busy = false;
    }
  }

  /** The app stayed away past its reconnect window: end the call on Vobiz. */
  async function endLostCall(watch, silent) {
    watched.delete(watch.uuid);
    watch.busy = true;
    // The app hosts a conference: it ends with the app (and for an inbound
    // call the reported UUID is the caller's leg, not the app's).
    const room = activeRoomOf(watch.uuid);
    if (room) {
      await endRoom(room, `the app lost its connection for ${secs(silent)} s`);
      return;
    }
    try {
      await vobizApi('DELETE', `/Call/${encodeURIComponent(watch.uuid)}/`);
      log('ok', `Call ${short(watch.uuid)}: no word from the app for ${secs(silent)} s, past its reconnect window; call ended so it is not billed on`);
    } catch (error) {
      if (!isGone(error)) log('!!', `Call ${short(watch.uuid)}: could not end the call: ${error.message}`);
    }
  }

  function forget(watch, why) {
    if (watched.get(watch.uuid) === watch) watched.delete(watch.uuid);
    log('..', `Call ${short(watch.uuid)}: ${why}; no longer watched`);
  }

  // ── DTMF test ────────────────────────────────────────────────────────────────
  //
  // Checks that keypad presses in the app reach Vobiz. Place a call to the
  // app's endpoint through the Vobiz API with answer_url = PUBLIC_URL/dtmf-test:
  // the answering app is asked for four digits, and Vobiz posts what it
  // received to /dtmf-test-digits, which logs it and reads it back.

  async function onDtmfTest(req, res, url, params) {
    if (isHangupEvent(params)) return sendText(res, 200, 'OK');
    log('..', `DTMF test call ${short(params.CallUUID || '')}: asking for four digits`);
    sendXml(res, `<Gather action="${esc(publicBase())}/dtmf-test-digits" method="POST" inputType="dtmf" numDigits="4" executionTimeout="30" digitEndTimeout="8">`
      + '<Speak>Please press four digits.</Speak></Gather><Speak>No digits were received.</Speak><Hangup/>');
  }

  async function onDtmfTestDigits(req, res, url, params) {
    const digits = String(params.Digits || '').replace(/[^0-9*#A-D]/g, '');
    log('ok', `DTMF test call ${short(params.CallUUID || '')}: Vobiz received "${digits}"`);
    sendXml(res, `<Speak>You pressed ${digits ? digits.split('').join(' ') : 'nothing'}.</Speak><Hangup/>`);
  }

  // ── Conference: the app's call becomes a conference room ────────────────────
  //
  // Vobiz mixes a conference in a room (<Conference>). Moving the app's call
  // into a room, dialling people into it and muting them are REST calls that
  // need the Auth Token, so the app asks this bridge:
  //
  //   POST /conference/add          the first time, both sides of the app's
  //                                 call move into a new room (Transfer API,
  //                                 legs=both); then the new person is dialled
  //                                 (Call API) with the room as answer XML
  //   POST /conference/state        who is in the room
  //   POST /conference/participant  mute, unmute, hold, resume or remove one
  //   POST /conference/end          end the room for everyone
  //
  // Vobiz's read API does not list a live room's members (its docs say so),
  // so the bridge keeps them from the enter and exit callbacks. Every leg
  // joins with stayAlone="true": Vobiz otherwise drops a member who is alone
  // in the room, even for the moment both sides of the call are moving in.
  // The app's own leg ends the room when it leaves (endConferenceOnExit), and
  // the bridge ends it when nobody else is left. Hold takes a person out of
  // the room onto looping music (Transfer API) and resume brings them back:
  // Vobiz has no hold for a member.
  //
  // A request that names its SIP user (X-Bridge-User) acts on that user's
  // calls only (the user must be on the live call); the bridge key alone may
  // act on any live call of the account.

  /** Conference rooms by name, and the room of every CallUUID in one. Memory only. */
  const rooms = new Map();
  const roomOfCall = new Map();
  /** Rooms being opened, by the CallUUID they are for (see onConferenceAdd). */
  const roomOpenings = new Map();
  /** Vobiz's account cap on conference members (max_conf_members). */
  const MAX_CONF_MEMBERS = 20;
  /** A leg on its way into the room that has not entered after this long is gone. */
  const MOVE_TIMEOUT_MS = deps.confMoveTimeoutMs ?? 20000;
  /** How often, at most, the bridge asks Vobiz whether people on hold are still there. */
  const HOLD_CHECK_MS = 5000;
  /** Member states in which a person is still part of the conference. */
  const PRESENT = new Set(['moving', 'dialing', 'joined', 'holding', 'on_hold', 'resuming']);
  const ACTIONS = new Set(['mute', 'unmute', 'hold', 'resume', 'remove']);

  async function onConferenceAdd(req, res) {
    const who = appCaller(req, res);
    if (!who) return;
    if (!config.authId || !config.authToken) return sendJson(res, 503, { error: 'VOBIZ_AUTH_ID and VOBIZ_AUTH_TOKEN are not set' });
    const body = await readJson(req);
    const uuid = String(body.call_uuid || '').toLowerCase();
    if (!CALL_UUID_RE.test(uuid)) return sendJson(res, 400, { error: 'call_uuid must be a Vobiz CallUUID' });
    const target = conferenceTarget(body);
    if (!target) return sendJson(res, 400, { error: 'Send number (E.164, e.g. +919876543210) or user (a SIP endpoint username)' });
    const callerId = String(body.caller_id || config.number || '').trim();
    if (!PSTN_RE.test(callerId)) {
      return sendJson(res, 400, { error: 'caller_id must be one of your Vobiz numbers in E.164 (VOBIZ_NUMBER is the default)' });
    }

    // Another add for this call may be opening its room: wait for it, so the
    // call is moved into one room only.
    while (roomOpenings.has(uuid)) await roomOpenings.get(uuid).catch(() => {});
    let room = roomForCall(uuid);
    if (room && !mayControl(room, who)) return sendJson(res, 403, { error: 'Not a conference of this SIP user' });
    if (room?.over) room = null;
    if (!room) {
      const opening = openConference(uuid, who, body);
      roomOpenings.set(uuid, opening);
      let opened;
      try {
        opened = await opening;
      } finally {
        if (roomOpenings.get(uuid) === opening) roomOpenings.delete(uuid);
      }
      if (!opened.room) return sendJson(res, opened.status, { error: opened.error });
      room = opened.room;
    }
    if (room.members.filter((m) => PRESENT.has(m.status)).length >= MAX_CONF_MEMBERS) {
      return sendJson(res, 409, { error: `A conference holds at most ${MAX_CONF_MEMBERS} people`, conference: publicRoom(room) });
    }

    const member = addMember(room, { role: 'added', label: target.label, status: 'dialing' });
    try {
      const placed = await vobizApi('POST', '/Call/', {
        from: callerId,
        to: target.to,
        answer_url: `${publicBase()}/conf-room/${roomRef(room.name, 'added')}`,
        answer_method: 'POST',
        hangup_url: `${publicBase()}/conf-dial/${roomRef(room.name, 'dial')}`,
        hangup_method: 'POST',
        ring_timeout: String(config.ringSeconds),
      });
      member.requestUuid = String(placed?.request_uuid || placed?.RequestUUID || '').toLowerCase() || null;
      if (member.requestUuid) roomOfCall.set(member.requestUuid, room.name);
      log('->', `Conference ${room.name}: dialling ${target.label}`);
    } catch (error) {
      member.status = 'failed';
      member.reason = 'not dialled';
      log('!!', `Conference ${room.name}: Vobiz did not dial ${target.label}: ${error.message}`);
      return sendJson(res, 502, { error: `Vobiz did not dial ${target.label}`, conference: publicRoom(room) });
    }
    sendJson(res, 200, publicRoom(room));
  }

  async function onConferenceState(req, res) {
    const found = await conferenceRequest(req, res);
    if (!found) return;
    await checkHeld(found.room);
    sendJson(res, 200, publicRoom(found.room));
  }

  async function onConferenceParticipant(req, res) {
    const found = await conferenceRequest(req, res);
    if (!found) return;
    const { room, body } = found;
    const action = String(body.action || '');
    if (!ACTIONS.has(action)) return sendJson(res, 400, { error: 'action must be mute, unmute, hold, resume or remove' });
    const member = room.members.find((m) => m.id === String(body.participant_id || ''));
    if (!member) return sendJson(res, 404, { error: 'No such participant' });
    if (member.role === 'host') return sendJson(res, 400, { error: 'That is you: use the call\'s own Mute and Hang up' });
    if (room.over) return sendJson(res, 409, { error: 'The conference has ended', conference: publicRoom(room) });
    let refused;
    try {
      refused = await participantAction(room, member, action);
    } catch (error) {
      log('!!', `Conference ${room.name}: could not ${action} ${member.label}: ${error.message}`);
      return sendJson(res, 502, { error: `Vobiz did not ${action} ${member.label}`, conference: publicRoom(room) });
    }
    if (refused) return sendJson(res, 409, { error: refused, conference: publicRoom(room) });
    sendJson(res, 200, publicRoom(room));
  }

  async function onConferenceEnd(req, res) {
    const found = await conferenceRequest(req, res);
    if (!found) return;
    await endRoom(found.room, 'ended by the app');
    sendJson(res, 200, publicRoom(found.room));
  }

  /**
   * The room of the request's call_uuid, after the caller has shown it may
   * act on it; otherwise answers the request itself and returns null.
   */
  async function conferenceRequest(req, res) {
    const who = appCaller(req, res);
    if (!who) return null;
    const body = await readJson(req);
    const uuid = String(body.call_uuid || '').toLowerCase();
    const room = CALL_UUID_RE.test(uuid) ? roomForCall(uuid) : null;
    if (!room) {
      sendJson(res, 404, { error: 'No conference for this call' });
      return null;
    }
    if (!mayControl(room, who)) {
      sendJson(res, 403, { error: 'Not a conference of this SIP user' });
      return null;
    }
    return { room, body, who };
  }

  function mayControl(room, who) {
    return who.operator || room.hostUser === who.username;
  }

  /** Who to dial: { to, label } from `number` (E.164) or `user` (a SIP endpoint), or null. */
  function conferenceTarget(body) {
    const number = String(body.number || '').trim();
    const user = endpointUsername(body.user || '');
    if (number && !user) return PSTN_RE.test(number) ? { to: number, label: number } : null;
    if (user && !number) return USERNAME_RE.test(user) ? { to: `sip:${user}@registrar.vobiz.ai`, label: user } : null;
    return null;
  }

  /**
   * Which leg of call `uuid` is the app's (the host) and who is at the other
   * end, or null when the call is not live or not this SIP user's.
   */
  async function conferenceLegs(uuid, who, body) {
    // An inbound call this bridge rang: `uuid` is the caller's own leg and
    // the app is the leg the Dial reached.
    const own = calls.get(uuid);
    if (own && own.bridged && !own.over && (who.operator || isCallOf(own, who.username))) {
      return { hostLeg: 'bleg', hostUser: who.username || own.answeredBy || own.targets[0] || '', guestLabel: own.from || 'Caller' };
    }
    let live;
    try {
      live = await vobizApi('GET', `/Call/${encodeURIComponent(uuid)}/?status=live`);
    } catch {
      return null;
    }
    if (!live) return null;
    const from = endpointUsername(live.from);
    const to = endpointUsername(live.to);
    let hostLeg;
    if (who.operator) hostLeg = body.host_leg === 'bleg' ? 'bleg' : 'aleg';
    else if (from === who.username) hostLeg = 'aleg';
    else if (to === who.username) hostLeg = 'bleg';
    else return null;
    return {
      hostLeg,
      hostUser: hostLeg === 'aleg' ? from : to,
      guestLabel: displayNumber(hostLeg === 'aleg' ? live.to : live.from) || 'Caller',
    };
  }

  /** Opens a room for call `uuid` and moves both sides into it: { room }, or { status, error }. */
  async function openConference(uuid, who, body) {
    const legs = await conferenceLegs(uuid, who, body);
    if (!legs) return { status: 403, error: 'Not a live call of this SIP user' };
    const room = openRoom(uuid, legs);
    try {
      await moveIntoRoom(room);
    } catch (error) {
      log('!!', `Conference ${room.name}: Vobiz did not move call ${short(uuid)} into it: ${error.message}`);
      forgetRoom(room);
      return { status: 502, error: 'Vobiz did not move the call into a conference' };
    }
    return { room };
  }

  function openRoom(uuid, legs) {
    const name = `vc-${uuid.slice(0, 8)}-${crypto.randomBytes(3).toString('hex')}`;
    const room = {
      name,
      aLeg: uuid,
      hostLeg: legs.hostLeg,
      hostUser: legs.hostUser,
      members: [],
      nextId: 1,
      createdAt: Date.now(),
      over: false,
      endedAt: 0,
      endReason: null,
      holdCheckAt: 0,
    };
    rooms.set(name, room);
    roomOfCall.set(uuid, name);
    addMember(room, { role: 'host', label: legs.hostUser || 'You', status: 'moving' });
    addMember(room, { role: 'guest', label: legs.guestLabel, status: 'moving' });
    const timer = setTimeout(() => void movedCheck(room), MOVE_TIMEOUT_MS);
    timer.unref?.();
    log('->', `Conference ${name}: call ${short(uuid)} becomes a conference hosted by ${legs.hostUser || 'the app'}`);
    return room;
  }

  /** Both sides of the call go into the room: the app's leg as host, the other as guest. */
  async function moveIntoRoom(room) {
    const host = room.hostLeg;
    const guest = host === 'aleg' ? 'bleg' : 'aleg';
    await vobizApi('POST', `/Call/${encodeURIComponent(room.aLeg)}/`, {
      legs: 'both',
      [`${host}_url`]: `${publicBase()}/conf-room/${roomRef(room.name, 'host')}`,
      [`${host}_method`]: 'POST',
      [`${guest}_url`]: `${publicBase()}/conf-room/${roomRef(room.name, 'guest')}`,
      [`${guest}_method`]: 'POST',
    });
  }

  /**
   * A side of the call that Vobiz never asked for the room's XML did not
   * move (the transfer failed for it, or it hung up first). One that did ask
   * is on its way in, even if its enter callback is late.
   */
  async function movedCheck(room) {
    if (room.over) return;
    for (const member of room.members) {
      if (member.status === 'moving' && !member.callUuid && (member.role === 'host' || member.role === 'guest')) {
        member.status = 'left';
        member.reason = 'did not reach the room';
        log('!!', `Conference ${room.name}: ${member.label} did not reach the room`);
      }
    }
    if (room.members.find((m) => m.role === 'host')?.status === 'left') {
      await endRoom(room, 'the app did not reach the room');
    } else {
      await maybeEndRoom(room);
    }
  }

  function addMember(room, fields) {
    const member = {
      id: `p${room.nextId++}`,
      role: 'added',
      label: '',
      status: 'dialing',
      callUuid: null,
      requestUuid: null,
      memberId: null,
      muted: false,
      reason: null,
      ...fields,
    };
    room.members.push(member);
    return member;
  }

  /** The member a leg asking for the room's XML is: by its CallUUID, else by its role. */
  function legMember(room, role, uuid, params) {
    const known = uuid && room.members.find((m) => m.callUuid === uuid || m.requestUuid === uuid);
    if (known) return known;
    if (role === 'host' || role === 'guest') return room.members.find((m) => m.role === role && !m.callUuid) || null;
    const to = displayNumber(params.To || '');
    const dialing = room.members.filter((m) => m.role === 'added' && m.status === 'dialing' && !m.callUuid);
    return dialing.find((m) => displayNumber(m.label) === to) || dialing[0] || null;
  }

  /** Vobiz asks for a leg's XML: the leg moving in, a dialled person who answered, or a resume. */
  async function onConfRoom(req, res, url, params) {
    const ref = roomFromPath(url);
    if (!ref || !['host', 'guest', 'added'].includes(ref.role)) return sendXml(res, '<Hangup/>');
    if (isHangupEvent(params)) return sendText(res, 200, 'OK');
    const room = ref.room;
    if (!room || room.over) return sendXml(res, '<Hangup/>');
    const uuid = String(params.CallUUID || '').toLowerCase();
    const member = legMember(room, ref.role, uuid, params);
    if (member) {
      if (uuid) {
        member.callUuid = uuid;
        roomOfCall.set(uuid, room.name);
      }
      if (member.status !== 'resuming') member.status = 'moving';
    }
    return sendXml(res, roomXml(room, ref.role === 'host'));
  }

  function roomXml(room, host) {
    const events = `${publicBase()}/conf-events/${roomRef(room.name, 'events')}`;
    return `  <Conference stayAlone="true" startConferenceOnEnter="true" endConferenceOnExit="${host ? 'true' : 'false'}" callbackUrl="${esc(events)}" callbackMethod="POST">${esc(room.name)}</Conference>`;
  }

  /** A person on hold: out of the room, on looping music until resumed. */
  async function onConfHold(req, res, url) {
    const ref = roomFromPath(url);
    if (!ref || ref.role !== 'hold' || !ref.room || ref.room.over) return sendXml(res, '<Hangup/>');
    return sendXml(res, `  <Play loop="0">${esc(publicBase())}/hold.wav</Play>`);
  }

  /** Vobiz: someone entered or left the room. */
  async function onConfEvents(req, res, url, params) {
    sendText(res, 200, 'OK');
    const ref = roomFromPath(url);
    const room = ref?.role === 'events' ? ref.room : null;
    if (!room || (params.ConferenceName && params.ConferenceName !== room.name)) return;
    const event = String(params.Event || '');
    const action = String(params.ConferenceAction || '').toLowerCase()
      || (event === 'ConferenceEnter' ? 'enter' : event === 'ConferenceExit' ? 'exit' : '');
    const uuid = String(params.CallUUID || '').toLowerCase();
    let member = uuid ? room.members.find((m) => m.callUuid === uuid || m.requestUuid === uuid) : null;

    if (action === 'enter') {
      if (!member) {
        member = addMember(room, { role: 'other', label: displayNumber(params.From) || 'Participant', status: 'moving', callUuid: uuid || null });
        if (uuid) roomOfCall.set(uuid, room.name);
      }
      member.memberId = String(params.ConferenceMemberID || '') || null;
      member.status = 'joined';
      member.reason = null;
      log('ok', `Conference ${room.name}: ${member.label} joined`);
      // Back from hold: the new member is unmuted; mute it again if it was.
      if (member.muted && member.memberId) {
        background(vobizApi('POST', memberPath(room, member, 'Mute/')), 'mute after resume');
      }
      return;
    }
    if (action !== 'exit' || !member || !PRESENT.has(member.status)) return;
    member.memberId = null;
    if (member.status === 'holding') {
      member.status = 'on_hold';
      log('..', `Conference ${room.name}: ${member.label} is on hold`);
      return;
    }
    if (member.status === 'on_hold' || member.status === 'resuming') return;
    member.status = 'left';
    log('..', `Conference ${room.name}: ${member.label} left`);
    if (member.role === 'host') await endRoom(room, 'the app left');
    else await maybeEndRoom(room);
  }

  /** Vobiz: a call the bridge dialled into the room has ended (hangup_url). */
  async function onConfDialEnded(req, res, url, params) {
    sendText(res, 200, 'OK');
    const ref = roomFromPath(url);
    const room = ref?.role === 'dial' ? ref.room : null;
    if (!room) return;
    const ids = [params.CallUUID, params.RequestUUID].map((v) => String(v || '').toLowerCase()).filter(Boolean);
    const member = room.members.find((m) => ids.includes(m.callUuid) || ids.includes(m.requestUuid));
    if (!member || !PRESENT.has(member.status)) return;
    if (member.status === 'dialing') {
      member.status = 'failed';
      member.reason = hangupReason(params);
      log('..', `Conference ${room.name}: ${member.label} did not join (${member.reason})`);
    } else {
      member.status = 'left';
      log('..', `Conference ${room.name}: ${member.label} hung up`);
    }
    member.memberId = null;
    await maybeEndRoom(room);
  }

  /** Does `action` to `member`. Returns why it cannot be done now, or null when done. */
  async function participantAction(room, member, action) {
    const inRoom = member.status === 'joined' && Boolean(member.memberId);
    if (action === 'mute' || action === 'unmute') {
      if (!inRoom) return `${member.label} is not in the room`;
      await vobizApi(action === 'mute' ? 'POST' : 'DELETE', memberPath(room, member, 'Mute/'));
      member.muted = action === 'mute';
      log('ok', `Conference ${room.name}: ${member.label} ${action}d`);
      return null;
    }
    if (action === 'hold') {
      if (!inRoom || !member.callUuid) return `${member.label} is not in the room`;
      member.status = 'holding';
      try {
        await vobizApi('POST', `/Call/${encodeURIComponent(member.callUuid)}/`, {
          legs: 'aleg',
          aleg_url: `${publicBase()}/conf-hold/${roomRef(room.name, 'hold')}`,
          aleg_method: 'POST',
        });
      } catch (error) {
        member.status = 'joined';
        throw error;
      }
      log('ok', `Conference ${room.name}: ${member.label} goes on hold`);
      return null;
    }
    if (action === 'resume') {
      if (!['on_hold', 'holding'].includes(member.status) || !member.callUuid) return `${member.label} is not on hold`;
      const previous = member.status;
      member.status = 'resuming';
      try {
        await vobizApi('POST', `/Call/${encodeURIComponent(member.callUuid)}/`, {
          legs: 'aleg',
          aleg_url: `${publicBase()}/conf-room/${roomRef(room.name, member.role === 'guest' ? 'guest' : 'added')}`,
          aleg_method: 'POST',
        });
      } catch (error) {
        member.status = previous;
        throw error;
      }
      log('ok', `Conference ${room.name}: ${member.label} comes back from hold`);
      return null;
    }
    // remove
    if (inRoom) {
      await vobizApi('DELETE', memberPath(room, member, ''));
    } else if (PRESENT.has(member.status) && (member.callUuid || member.requestUuid)) {
      try {
        await vobizApi('DELETE', `/Call/${encodeURIComponent(member.callUuid || member.requestUuid)}/`);
      } catch (error) {
        if (!isGone(error)) throw error;
      }
    } else {
      return `${member.label} is not on the call`;
    }
    member.status = 'left';
    member.reason = 'removed';
    member.memberId = null;
    log('ok', `Conference ${room.name}: ${member.label} removed`);
    await maybeEndRoom(room);
    return null;
  }

  /**
   * People on hold are outside the room, so no exit event says when they
   * hang up: now and then ask Vobiz whether their calls are still live.
   */
  async function checkHeld(room) {
    if (room.over || Date.now() - room.holdCheckAt < HOLD_CHECK_MS) return;
    const held = room.members.filter((m) => m.status === 'on_hold' && m.callUuid);
    if (!held.length) return;
    room.holdCheckAt = Date.now();
    for (const member of held) {
      try {
        await vobizApi('GET', `/Call/${encodeURIComponent(member.callUuid)}/?status=live`);
      } catch (error) {
        if (!isGone(error)) continue;
        member.status = 'left';
        log('..', `Conference ${room.name}: ${member.label} hung up while on hold`);
      }
    }
    await maybeEndRoom(room);
  }

  /** Only the app is left (nobody else in the room, ringing or on hold): end the room. */
  async function maybeEndRoom(room) {
    if (room.over) return;
    if (room.members.some((m) => m.role !== 'host' && PRESENT.has(m.status))) return;
    await endRoom(room, 'everyone else left');
  }

  /** Ends the room for everyone, including people on hold and calls still ringing. */
  async function endRoom(room, why) {
    if (room.over) return;
    room.over = true;
    room.endedAt = Date.now();
    room.endReason = why;
    const outside = room.members.filter((m) => ['dialing', 'moving', 'holding', 'on_hold', 'resuming'].includes(m.status)
      && m.role !== 'host' && (m.callUuid || m.requestUuid));
    for (const member of room.members) {
      if (PRESENT.has(member.status)) member.status = 'left';
      member.memberId = null;
    }
    try {
      await vobizApi('DELETE', `/Conference/${encodeURIComponent(room.name)}/`);
    } catch (error) {
      if (!isGone(error)) log('!!', `Conference ${room.name}: could not end it: ${error.message}`);
    }
    await Promise.all(outside.map((member) => vobizApi('DELETE', `/Call/${encodeURIComponent(member.callUuid || member.requestUuid)}/`)
      .catch((error) => { if (!isGone(error)) log('!!', `Conference ${room.name}: could not hang up ${member.label}: ${error.message}`); })));
    log('ok', `Conference ${room.name} ended: ${why}`);
  }

  function forgetRoom(room) {
    rooms.delete(room.name);
    for (const [uuid, name] of roomOfCall) if (name === room.name) roomOfCall.delete(uuid);
  }

  /** The room `uuid` is in (the app's call or any member's leg), or null. */
  function roomForCall(uuid) {
    const name = roomOfCall.get(uuid);
    return (name && rooms.get(name)) || null;
  }

  function activeRoomOf(uuid) {
    const room = roomForCall(String(uuid || '').toLowerCase());
    return room && !room.over ? room : null;
  }

  function memberPath(room, member, suffix) {
    return `/Conference/${encodeURIComponent(room.name)}/Member/${encodeURIComponent(member.memberId)}/${suffix}`;
  }

  /** `<room>.<role>.<tag>`: the tag proves the bridge wrote this path for this room and role. */
  function roomRef(name, role) {
    return `${encodeURIComponent(name)}.${role}.${roomTag(name, role)}`;
  }

  function roomTag(name, role) {
    return crypto.createHmac('sha256', state.webhookSecret).update(`conf:${name}:${role}`).digest('base64url').slice(0, 22);
  }

  /** { room (or null when it is gone), role } from a /conf-… path, or null if the tag is wrong. */
  function roomFromPath(url) {
    const parts = (url.pathname.split('/')[2] || '').split('.');
    if (parts.length !== 3) return null;
    let name;
    try { name = decodeURIComponent(parts[0]); } catch { return null; }
    if (!safeEqual(parts[2], roomTag(name, parts[1]))) return null;
    return { room: rooms.get(name) || null, role: parts[1] };
  }

  /** The state the app shows. */
  function publicRoom(room) {
    return {
      room: room.name,
      active: !room.over,
      ...(room.over && room.endReason ? { ended_reason: room.endReason } : {}),
      participants: room.members.map((m) => ({
        id: m.id,
        label: m.label,
        you: m.role === 'host',
        role: m.role,
        status: ({ moving: 'connecting', resuming: 'connecting', holding: 'on_hold' })[m.status] || m.status,
        muted: m.muted,
        ...(m.reason ? { reason: m.reason } : {}),
      })),
    };
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function keyMatches(req) {
    const header = String(req.headers['x-bridge-key'] || '');
    return Boolean(header) && safeEqual(header, state.bridgeKey);
  }

  function publicBase() {
    return config.publicUrl || `http://localhost:${config.port}`;
  }

  function background(promise, label) {
    promise.catch((error) => log('!!', `${label} failed: ${error.message}`));
  }

  function loadState() {
    try {
      const json = JSON.parse(fs.readFileSync(config.stateFile, 'utf8'));
      const object = (v) => (v && typeof v === 'object' ? v : {});
      // Only these keys: an older file's `devices` (push tokens, device
      // secrets' hashes) is dropped by the save at start.
      return {
        bridgeKey: json.bridgeKey || '',
        webhookSecret: json.webhookSecret || '',
        nonces: object(json.nonces),
      };
    } catch {
      return { bridgeKey: '', webhookSecret: '', nonces: {} };
    }
  }

  function saveState() {
    const tmp = `${config.stateFile}.tmp`;
    // The bridge key and the webhook secret: this user only (Linux, macOS).
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
    fs.chmodSync(tmp, 0o600);
    fs.renameSync(tmp, config.stateFile);
  }

  return { server, config, state, calls, start, close, sweep, verifySignatures, linkVobizNumber };
}

// ── Module helpers ───────────────────────────────────────────────────────────

/** Settings that would leave the server open. Empty when it is safe to start. */
export function configProblems(config, env, allowUnsigned) {
  const problems = [];
  if (env.VERIFY_SIGNATURES === 'false') {
    problems.push('VERIFY_SIGNATURES=false is no longer supported; for local testing only, set ALLOW_UNSIGNED_WEBHOOKS=true');
  }
  // The key lets anyone mint tokens and manage calls, so a short key or a
  // sentence pasted in as one (a description left on the BRIDGE_KEY line)
  // is refused. Empty: the server makes one.
  const key = String(env.BRIDGE_KEY || '').trim();
  if (key && (key.length < 16 || /\s/.test(key))) {
    problems.push('BRIDGE_KEY must be at least 16 characters with no spaces (leave it empty and the server makes one)');
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

function esc(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function short(id) {
  return String(id).slice(0, 8);
}

/**
 * `value` (any JSON) with every occurrence of each of `secrets` in its
 * strings replaced, and every string under a key that names a token (such as
 * push_token) replaced whole.
 */
function hideSecrets(value, secrets, key = '') {
  if (typeof value === 'string') {
    if (value && /token/i.test(key)) return '[hidden]';
    return secrets.reduce((text, secret) => text.split(secret).join('[hidden]'), value);
  }
  if (Array.isArray(value)) return value.map((item) => hideSecrets(item, secrets, key));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, hideSecrets(item, secrets, name)]));
  }
  return value;
}

/** ": <Vobiz's own reason>" (message, error or detail) for a log line, or ''. */
function vobizReason(body) {
  const reason = [body?.message, body?.error, body?.detail].find((v) => typeof v === 'string' && v.trim());
  return reason ? `: ${reason.trim().slice(0, 120)}` : '';
}

/** A Vobiz API error for a call that no longer exists. */
function isGone(error) {
  return / → 404 /.test(String(error?.message || ''));
}

/** Why a dialled call ended before it was answered, in a few words. */
function hangupReason(params) {
  const cause = String(params.HangupCauseName || params.HangupCause || params.CallStatus || '').toLowerCase();
  if (/busy/.test(cause)) return 'busy';
  if (/no.?answer|no_user_response|timeout|cancel/.test(cause)) return 'no answer';
  if (/reject|declin/.test(cause)) return 'declined';
  return cause ? cause.replace(/_/g, ' ') : 'not answered';
}

function secs(ms) {
  return (ms / 1000).toFixed(1);
}

function csv(value) {
  return String(value || '').split(',').map((s) => endpointUsername(s)).filter((s) => USERNAME_RE.test(s));
}

function clampInt(value, fallback, min, max) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

/** Whether two SIP user names are the same, ignoring case as the endpoint check does. */
function sameUser(a, b) {
  return Boolean(a) && Boolean(b) && String(a).toLowerCase() === String(b).toLowerCase();
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

/**
 * The settings in the text of a .env file: `NAME=value` lines, `#` lines are
 * comments. A quoted value ("…" or '…') is kept as written. An unquoted value
 * ends at a ` #` comment, and may not contain a space: that is almost always
 * a description left on the setting's line, which would silently become the
 * value. Returns { values, problems }; a problem names the line, never the
 * value.
 */
export function parseEnv(text) {
  const values = {};
  const problems = [];
  String(text).split(/\r?\n/).forEach((line, index) => {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!match || match[2].startsWith('#')) return;
    const [, name, rest] = match;
    let value;
    if (rest[0] === '"' || rest[0] === '\'') {
      const close = rest.indexOf(rest[0], 1);
      const after = close < 0 ? '' : rest.slice(close + 1);
      if (close < 0 || (after && !/^\s+#/.test(after))) {
        problems.push(`line ${index + 1}: the quoted value of ${name} is not closed, or has text after it`);
        return;
      }
      value = rest.slice(1, close);
    } else {
      value = rest.replace(/\s+#.*$/, '');
      if (/\s/.test(value)) {
        problems.push(`line ${index + 1}: the value of ${name} has a space in it. Put descriptions on their own # line, and quote a value that really has spaces`);
        return;
      }
    }
    values[name] = value;
  });
  return { values, problems };
}

/** Sets the .env file's settings that the environment does not already have. */
function loadEnvFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return;
  }
  const { values, problems } = parseEnv(text);
  if (problems.length) {
    const error = new Error(`${file} cannot be read safely:\n  - ${problems.join('\n  - ')}`);
    error.code = 'BRIDGE_CONFIG';
    throw error;
  }
  for (const [name, value] of Object.entries(values)) {
    if (process.env[name] === undefined) process.env[name] = value;
  }
}

function sendWav(res, wav) {
  res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': wav.length, 'Cache-Control': 'public, max-age=3600' });
  res.end(wav);
}

/**
 * `seconds` of an Indian call-progress tone (400 Hz modulated at 25 Hz),
 * sounding during `bursts` ([start, end] in seconds), as 8 kHz 16-bit mono
 * WAV. Busy: 0.75 s on/off. `freqs` replaces the tone's frequencies (the
 * connection-lost beep is 1 kHz).
 */
function makeToneWav(seconds, bursts, freqs = [375, 425]) {
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
      value = 0.3 * fade * freqs.reduce((sum, f) => sum + Math.sin(2 * Math.PI * f * t), 0) / freqs.length;
    }
    pcm.writeInt16LE(Math.round(value * 32767), i * 2);
  }
  return wavFile(pcm, rate);
}

/**
 * Eight seconds of quiet hold music (a slow arpeggio, half a second a note,
 * each faded in and out so the loop has no clicks) as 8 kHz 16-bit mono WAV.
 */
function makeHoldMusicWav() {
  const rate = 8000;
  const notes = [261.63, 329.63, 392.0, 523.25, 392.0, 329.63, 293.66, 349.23,
    440.0, 587.33, 440.0, 349.23, 261.63, 329.63, 392.0, 329.63];
  const noteSeconds = 0.5;
  const samples = Math.round(rate * noteSeconds * notes.length);
  const pcm = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i += 1) {
    const t = i / rate;
    const n = Math.min(notes.length - 1, Math.floor(t / noteSeconds));
    const local = t - n * noteSeconds;
    const envelope = Math.min(1, local / 0.03) * Math.min(1, (noteSeconds - local) / 0.15);
    const f = notes[n];
    const value = 0.12 * envelope * (Math.sin(2 * Math.PI * f * t) + 0.3 * Math.sin(4 * Math.PI * f * t)) / 1.3;
    pcm.writeInt16LE(Math.round(value * 32767), i * 2);
  }
  return wavFile(pcm, rate);
}

/** 16-bit mono PCM samples as a WAV file. */
function wavFile(pcm, rate) {
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
  try {
    loadEnvFile(path.join(HERE, '.env'));
    createBridge().start();
  } catch (error) {
    if (error.code !== 'BRIDGE_CONFIG') throw error;
    console.error(error.message);
    console.error('Fix .env (see .env.example) and start again. ALLOW_UNSIGNED_WEBHOOKS=true skips the check for local tests only.');
    process.exit(1);
  }
}
