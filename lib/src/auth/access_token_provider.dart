import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/vobiz_client.dart';
import '../errors/vobiz_exception.dart';
import '../events/connection_event.dart';
import '../events/error_event.dart';
import '../models/auth/auth_mode.dart';
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
  /// something that is not a Vobiz token. Dispose the session when the user
  /// signs out (it does not disconnect the client).
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

  Timer? _timer;
  Timer? _retryTimer;
  DateTime? _nextRefresh;
  String? _current;
  int _consecutiveRefreshes = 0;
  bool _busy = false;
  bool _disposed = false;

  /// When the session will next ask for a token; null when nothing is
  /// scheduled (after a failure, or once disposed).
  DateTime? get nextRefreshAt => _nextRefresh;

  /// Failures the session could not recover from: the provider threw, or the
  /// registrar kept refusing fresh tokens.
  Stream<VobizException> get failures => _failures.stream;

  /// Asks the provider for a new token now and registers with it.
  Future<void> refresh() => _renew(VobizAccessTokenRequest.refresh);

  /// Stops refreshing and watching the client. Does not disconnect it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRefresh = null;
    await _errorSub.cancel();
    await _connectionSub.cancel();
    await _failures.close();
  }

  Future<void> _signIn() async {
    final token = await _fetch(VobizAccessTokenRequest.signIn);
    await client.connectWithAccessToken(token);
    _schedule();
  }

  Future<void> _renew(VobizAccessTokenRequest request) async {
    if (_disposed) throw StateError('This access token session was disposed');
    _busy = true;
    try {
      final token = await _fetch(request);
      if (_disposed) return;
      await client.updateAccessToken(token);
      _schedule();
    } finally {
      _busy = false;
    }
  }

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
  /// expiry (never sooner than [minimumRefreshDelay]).
  void _schedule() {
    _timer?.cancel();
    final current = client.accessToken;
    if (_disposed || current == null) {
      _nextRefresh = null;
      return;
    }
    final at = now();
    var delay = current.expiresAt.difference(at) - refreshBefore;
    if (delay < minimumRefreshDelay) delay = minimumRefreshDelay;
    _nextRefresh = at.add(delay);
    _timer = Timer(delay, () {
      _timer = null;
      _renew(VobizAccessTokenRequest.expiring).catchError((Object e) {
        _nextRefresh = null;
        _fail(e is VobizException
            ? e
            : VobizAccessTokenException('Renewing the access token failed: $e', cause: e));
      });
    });
  }

  void _onConnection(ConnectionEvent event) {
    if (event.registrationState == RegistrationState.registered) {
      _consecutiveRefreshes = 0;
    }
  }

  void _onError(ErrorEvent event) {
    if (_disposed || _busy) return;
    if (event.code != VobizErrorCode.registrationFailed) return;
    if (client.authMode != VobizAuthMode.accessToken) return;
    final cause = event.cause;
    final tokenError = cause is VobizAccessTokenException ? cause.tokenError : null;
    if (_consecutiveRefreshes >= maxRefreshes) {
      _timer?.cancel();
      _nextRefresh = null;
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
        if (_disposed) return;
        client.updateAccessToken(current).then((_) => _schedule()).catchError((Object e) {
          _fail(e is VobizException
              ? e
              : VobizAccessTokenException('Signing in again failed: $e', cause: e));
        });
      });
      return;
    }
    _renew(VobizAccessTokenRequest.rejected).catchError((Object e) {
      _fail(e is VobizException
          ? e
          : VobizAccessTokenException('Signing in again failed: $e', cause: e));
    });
  }

  void _fail(VobizException e) {
    if (!_failures.isClosed) _failures.add(e);
  }
}
