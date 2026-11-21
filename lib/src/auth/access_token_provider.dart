import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/vobiz_client.dart';
import '../errors/vobiz_exception.dart';
import '../events/connection_event.dart';
import '../events/error_event.dart';
import '../models/auth/auth_mode.dart';
import '../state/connection_state.dart';
import '../state/registration_state.dart';

/// Why the SDK is asking the app's [VobizAccessTokenProvider] for a token.
enum VobizAccessTokenRequest {
  /// First sign-in.
  signIn,

  /// The current token expires soon: [VobizAccessTokenSession.refreshBefore]
  /// ahead of its `exp`.
  expiring,

  /// The registrar refused the current token (expired, wrong signature, too
  /// many sign-ins…). Mint a new one; do not return a cached token.
  rejected,

  /// The app called [VobizAccessTokenSession.refresh].
  refresh,
}

/// Returns a fresh access token (JWT) for the signed-in user.
///
/// Your backend mints it with `POST /api/v1/Account/{auth_id}/JWT/Token/`,
/// using the account Auth Token, which never leaves your server, after it
/// has authenticated your app's user with its own session. Put that user's
/// id in `sub` so each person registers as their own `<sub>_<auth_id>`. See
/// CREDENTIALS.md. The web SDK's equivalent is the `getAccessToken` of
/// `loginWithAccessTokenGenerator`.
///
/// Throwing, or returning an empty string, fails the request with
/// [VobizAccessTokenException].
typedef VobizAccessTokenProvider = Future<String> Function(VobizAccessTokenRequest request);

/// Sign-in through a [VobizAccessTokenProvider].
extension VobizClientAccessTokenProvider on VobizClient {
  /// Signs in with an access token from [provider], and keeps the sign-in
  /// alive: [refreshBefore] ahead of each token's expiry the provider is asked
  /// again ([VobizAccessTokenRequest.expiring]) and the client registers with
  /// the new token on the same socket, without touching a call. When the
  /// registrar refuses a token, the provider is asked again
  /// ([VobizAccessTokenRequest.rejected]), up to [maxRefreshes] times in a
  /// row before the session gives up and reports it on
  /// [VobizAccessTokenSession.failures].
  ///
  /// The expiry is timed by the registrar's own count of the time a token
  /// has left (from its 200 OK) once it has accepted that token, so a phone
  /// whose clock is wrong still renews in time; until then, by the device's
  /// clock. When the provider fails, or the token it returns cannot be
  /// presented, the session asks again after
  /// [VobizAccessTokenSession.firstRetryDelay], doubling the wait up to
  /// [VobizAccessTokenSession.maximumRetryDelay], and reports each failure on
  /// [VobizAccessTokenSession.failures].
  ///
  /// A token the registrar calls not valid yet (10005, its clock behind the
  /// minting server's) is presented again after
  /// [VobizAccessTokenSession.notValidYetRetryDelay] instead of asking for a
  /// new one.
  ///
  /// The same as the web SDK's `loginWithAccessTokenGenerator`, which
  /// refreshes 60 seconds before expiry.
  ///
  /// Completes once the REGISTER has been sent; watch
  /// [VobizClient.connectionEvents] for the registrar's answer. Throws
  /// [VobizAccessTokenException] when the provider fails or returns
  /// something that is not a Vobiz token; nothing is left running then.
  /// When the socket cannot be opened, the client's error is thrown unless
  /// the client retries the connection by itself (`SdkConfig.autoReconnect`):
  /// then the session is returned and keeps the token fresh, and the failure
  /// is reported on [VobizClient.connectionEvents] and
  /// [VobizClient.errorEvents] (`connect_failed`). Dispose the session when
  /// the user signs out (it does not disconnect the client); a client signed
  /// out without it stops the session's timers, and nothing more is asked.
  Future<VobizAccessTokenSession> connectWithAccessTokenProvider(
    VobizAccessTokenProvider provider, {
    Duration refreshBefore = const Duration(seconds: 60),
    int maxRefreshes = 1,
  }) async {
    final session =
        VobizAccessTokenSession._(this, provider, refreshBefore, maxRefreshes);
    try {
      await session._signIn();
    } catch (_) {
      await session.dispose();
      rethrow;
    }
    return session;
  }
}

/// Keeps a [VobizClient] signed in with access tokens from a
/// [VobizAccessTokenProvider]. Created by
/// [VobizClientAccessTokenProvider.connectWithAccessTokenProvider].
class VobizAccessTokenSession {
  VobizAccessTokenSession._(
      this.client, this._provider, this.refreshBefore, this.maxRefreshes) {
    _errorSub = client.errorEvents.listen(_onError);
    _connectionSub = client.connectionEvents.listen(_onConnection);
  }

  /// The shortest wait before asking for the next token, so a provider that
  /// hands out nearly expired tokens cannot make the session ask in a loop.
  static const Duration minimumRefreshDelay = Duration(seconds: 5);

  /// How long to wait before presenting a token again that the registrar
  /// called not valid yet (10005): its clock is a little behind the one that
  /// minted the token (`nbf` = now). A new token would have the same `nbf`
  /// problem, so the same one is presented again.
  static const Duration notValidYetRetryDelay = Duration(seconds: 3);

  /// How long to wait before asking the provider again after it failed, or
  /// after the token it returned could not be presented. Each failure in a
  /// row doubles the wait, up to [maximumRetryDelay].
  static const Duration firstRetryDelay = Duration(seconds: 5);

  /// The longest wait between two attempts: after failures in a row, and
  /// between tokens that arrive (nearly) expired.
  static const Duration maximumRetryDelay = Duration(seconds: 60);

  /// The clock the refresh is scheduled by.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The client this session signs in.
  final VobizClient client;

  /// How long before a token's `exp` the next one is fetched.
  final Duration refreshBefore;

  /// How many times in a row a refused token triggers a new one.
  final int maxRefreshes;

  final VobizAccessTokenProvider _provider;
  late final StreamSubscription<ErrorEvent> _errorSub;
  late final StreamSubscription<ConnectionEvent> _connectionSub;
  final StreamController<VobizException> _failures =
      StreamController<VobizException>.broadcast();

  /// The next time the provider is asked: ahead of the current token's
  /// expiry, or a retry after a failure.
  Timer? _timer;
  Timer? _retryTimer;
  DateTime? _nextRefresh;
  String? _current;

  /// The last token the registrar accepted (a `registered` event with it).
  String? _registered;

  /// The wait before the pending retry, while retrying after failures.
  Duration? _retryDelay;

  /// What [_timer] asks the provider for.
  VobizAccessTokenRequest _pendingRequest = VobizAccessTokenRequest.expiring;

  /// The wait used for a token that arrived (nearly) expired, and the token
  /// it was used for: doubled for each such token in a row.
  Duration? _clampedDelay;
  String? _clampedFor;

  int _consecutiveRefreshes = 0;
  bool _busy = false;
  bool _disposed = false;

  /// When the session will next ask for a token: ahead of the current
  /// token's expiry, or the retry after a failure. Null when nothing is
  /// scheduled: the session gave up, the client was signed out, or the
  /// session was disposed.
  DateTime? get nextRefreshAt => _nextRefresh;

  /// Failures the session reports: each failed attempt to get a token or
  /// present it (the session asks again after [firstRetryDelay], doubling the
  /// wait), and those it gives up on: the registrar kept refusing fresh
  /// tokens, or a token is for another user.
  Stream<VobizException> get failures => _failures.stream;

  /// Asks the provider for a new token now and registers with it.
  Future<void> refresh() => _renew(VobizAccessTokenRequest.refresh);

  /// Stops refreshing and watching the client. Does not disconnect it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopTimers();
    await _errorSub.cancel();
    await _connectionSub.cancel();
    await _failures.close();
  }

  Future<void> _signIn() async {
    final token = await _fetch(VobizAccessTokenRequest.signIn);
    try {
      await client.connectWithAccessToken(token);
    } catch (_) {
      if (!_clientRetriesWith(token)) rethrow;
    }
    _schedule();
  }

  Future<void> _renew(VobizAccessTokenRequest request) async {
    if (_disposed) throw StateError('This access token session was disposed');
    _busy = true;
    try {
      final token = await _fetch(request);
      if (_disposed) return;
      try {
        await client.updateAccessToken(token);
      } catch (_) {
        if (!_clientRetriesWith(token)) rethrow;
      }
      _retryDelay = null;
      _schedule();
    } finally {
      _busy = false;
    }
  }

  /// Whether the client took [token] and, its connection having failed,
  /// retries it by itself (`SdkConfig.autoReconnect`): the token is in use.
  bool _clientRetriesWith(String token) =>
      client.accessToken?.token == token.trim() &&
      client.connectionState == ConnectionStateStatus.reconnecting;

  Future<String> _fetch(VobizAccessTokenRequest request) async {
    final String token;
    try {
      token = await _provider(request);
    } on VobizException {
      rethrow;
    } catch (e) {
      throw VobizAccessTokenException('The access token provider failed: $e', cause: e);
    }
    if (token.trim().isEmpty) {
      throw const VobizAccessTokenException('The access token provider returned an empty token',
          tokenError: VobizAccessTokenException.invalidToken);
    }
    _current = token;
    return token;
  }

  /// Asks for the next token [refreshBefore] ahead of the current one's
  /// expiry. A token that arrives with less than that left is renewed after
  /// [minimumRefreshDelay], twice as long for the next such token in a row,
  /// up to [maximumRetryDelay].
  void _schedule() {
    final current = client.accessToken;
    if (_disposed || current == null) {
      _stopTimers();
      return;
    }
    // Once the registrar has accepted this token, its own count of the time
    // left (at that 200 OK) beats the device's clock, which can be wrong.
    final registrarLeft = _registered == current.token ? client.accessTokenTimeLeft : null;
    var delay = (registrarLeft ?? current.expiresAt.difference(now())) - refreshBefore;
    if (delay < minimumRefreshDelay) {
      if (_clampedFor != current.token) {
        _clampedFor = current.token;
        final last = _clampedDelay;
        _clampedDelay = last == null ? minimumRefreshDelay : _shorter(last * 2, maximumRetryDelay);
      }
      delay = _clampedDelay!;
    } else {
      _clampedDelay = null;
      _clampedFor = null;
    }
    _arm(delay, VobizAccessTokenRequest.expiring);
  }

  /// Asks the provider for a token ([request]) after [delay].
  void _arm(Duration delay, VobizAccessTokenRequest request) {
    _timer?.cancel();
    _pendingRequest = request;
    _nextRefresh = now().add(delay);
    _timer = Timer(delay, () {
      _timer = null;
      _nextRefresh = null;
      // Signed out (or signed in another way) without disposing the session.
      if (_disposed || client.authMode != VobizAuthMode.accessToken) return;
      final request = _pendingRequest;
      _renew(request).catchError((Object e) => _renewFailed(request, e));
    });
  }

  /// Reports a failed renewal and asks again later, unless asking again
  /// cannot help.
  void _renewFailed(VobizAccessTokenRequest request, Object e) {
    if (_disposed) return;
    if (client.authMode != VobizAuthMode.accessToken) {
      // Signed out meanwhile: nothing to renew, and nothing to report.
      _stopTimers();
      return;
    }
    _fail(e is VobizException
        ? e
        : VobizAccessTokenException(
            request == VobizAccessTokenRequest.rejected
                ? 'Signing in again failed: $e'
                : 'Renewing the access token failed: $e',
            cause: e));
    // A token for another user: another one from the same provider will be too.
    if (e is StateError || e is ArgumentError) {
      _stopTimers();
      return;
    }
    final last = _retryDelay;
    final delay = last == null ? firstRetryDelay : _shorter(last * 2, maximumRetryDelay);
    _retryDelay = delay;
    _arm(delay, request);
  }

  void _stopTimers() {
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRefresh = null;
    _retryDelay = null;
  }

  static Duration _shorter(Duration a, Duration b) => a < b ? a : b;

  void _onConnection(ConnectionEvent event) {
    if (_disposed) return;
    if (client.authMode != VobizAuthMode.accessToken) {
      // Signed out, or signed in another way: there is nothing to renew.
      _stopTimers();
      return;
    }
    if (event.registrationState != RegistrationState.registered) return;
    _consecutiveRefreshes = 0;
    final token = client.accessToken?.token;
    if (token == null || token == _registered) return;
    _registered = token;
    // Time the pending refresh by the registrar's clock now that it has
    // accepted this token. A retry after a failure keeps its own time.
    if (_timer != null && _retryDelay == null) _schedule();
  }

  void _onError(ErrorEvent event) {
    if (_disposed || _busy) return;
    if (event.code != VobizErrorCode.registrationFailed) return;
    if (client.authMode != VobizAuthMode.accessToken) return;
    if (_retryDelay != null && _timer != null) {
      // Already asking again after a failure, and no new token was presented
      // yet: the registrar refused the old one. Ask for a new one, not a
      // cached one, at that retry.
      _pendingRequest = VobizAccessTokenRequest.rejected;
      return;
    }
    final cause = event.cause;
    final tokenError = cause is VobizAccessTokenException ? cause.tokenError : null;
    if (_consecutiveRefreshes >= maxRefreshes) {
      _stopTimers();
      _fail(VobizAccessTokenException(
          'The registrar refused the access token, also after asking the provider '
          'for a new one: ${event.message}',
          tokenError: tokenError,
          cause: cause));
      return;
    }
    _consecutiveRefreshes++;
    final current = _current;
    if (tokenError == VobizAccessTokenException.notValidYet && current != null) {
      // Valid in a moment by the registrar's clock: present the same token
      // again then (a fresh one would carry the same "now" as its nbf).
      _retryTimer?.cancel();
      _retryTimer = Timer(notValidYetRetryDelay, () {
        _retryTimer = null;
        if (_disposed || client.authMode != VobizAuthMode.accessToken) return;
        client.updateAccessToken(current).then((_) => _schedule()).catchError((Object e) {
          _fail(e is VobizException
              ? e
              : VobizAccessTokenException('Signing in again failed: $e', cause: e));
        });
      });
      return;
    }
    _renew(VobizAccessTokenRequest.rejected)
        .catchError((Object e) => _renewFailed(VobizAccessTokenRequest.rejected, e));
  }

  void _fail(VobizException e) {
    if (!_failures.isClosed) _failures.add(e);
  }
}
