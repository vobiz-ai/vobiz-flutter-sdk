import 'dart:async';

import '../core/vobiz_client.dart';
import '../errors/vobiz_exception.dart';
import '../events/connection_event.dart';
import '../events/error_event.dart';
import '../models/auth/credential_config.dart';
import '../state/registration_state.dart';

/// Why the SDK is asking the app's [VobizCredentialsProvider] for SIP
/// credentials.
enum VobizCredentialsRequest {
  /// First sign-in. Return the credentials you have cached for this user if
  /// you have them; ask your backend otherwise.
  signIn,

  /// The registrar refused the last credentials (401/403): they were rotated
  /// or the endpoint was deleted. Ask your backend; do not return the cache.
  rejected,

  /// The app called [VobizCredentialsSession.refresh], for example after your
  /// backend rotated the endpoint's password.
  refresh,
}

/// Returns SIP endpoint credentials for the signed-in user.
///
/// Your own backend holds the Vobiz account Auth Token, creates one Vobiz
/// endpoint per user (agent, device owner) the first time it is needed, keeps
/// that endpoint's password, and hands it to the app after authenticating the
/// app's user with your own session. The account Auth Token never reaches the
/// device. See CREDENTIALS.md for a reference backend.
///
/// Throwing (or returning an empty username/password) fails the sign-in with
/// [VobizCredentialsException].
typedef VobizCredentialsProvider = Future<CredentialConfig> Function(
    VobizCredentialsRequest request);

/// Sign-in through a [VobizCredentialsProvider].
extension VobizClientCredentialsProvider on VobizClient {
  /// Signs in with SIP credentials from [provider], and keeps them working:
  /// when the registrar refuses them, the provider is asked again with
  /// [VobizCredentialsRequest.rejected] and the client re-registers, up to
  /// [maxRefreshes] times in a row before giving up.
  ///
  /// Completes once the REGISTER has been sent (like
  /// [VobizClient.connectWithCredentials]); watch
  /// [VobizClient.connectionEvents] for the registrar's answer.
  ///
  /// Throws [VobizCredentialsException] when the provider fails. Dispose the
  /// returned session (or call [VobizClient.disconnect] and dispose it) when
  /// the user signs out.
  Future<VobizCredentialsSession> connectWithCredentialsProvider(
    VobizCredentialsProvider provider, {
    int maxRefreshes = 1,
  }) async {
    final session = VobizCredentialsSession._(this, provider, maxRefreshes);
    try {
      await session._connect(VobizCredentialsRequest.signIn);
    } catch (_) {
      await session.dispose();
      rethrow;
    }
    return session;
  }
}

/// Keeps a [VobizClient] signed in with credentials from a
/// [VobizCredentialsProvider]. Created by
/// [VobizClientCredentialsProvider.connectWithCredentialsProvider].
class VobizCredentialsSession {
  VobizCredentialsSession._(this.client, this._provider, this.maxRefreshes) {
    _errorSub = client.errorEvents.listen(_onError);
    _connectionSub = client.connectionEvents.listen(_onConnection);
  }

  /// The client this session signs in.
  final VobizClient client;

  /// How many times in a row a refused registration triggers a refresh.
  final int maxRefreshes;

  final VobizCredentialsProvider _provider;
  late final StreamSubscription<ErrorEvent> _errorSub;
  late final StreamSubscription<ConnectionEvent> _connectionSub;
  final StreamController<VobizException> _failures =
      StreamController<VobizException>.broadcast();

  int _consecutiveRefreshes = 0;
  bool _busy = false;
  bool _disposed = false;

  /// Failures the session could not recover from: the provider threw, or the
  /// registrar kept refusing fresh credentials.
  Stream<VobizException> get failures => _failures.stream;

  /// Asks the provider for fresh credentials and re-registers with them.
  Future<void> refresh() => _connect(VobizCredentialsRequest.refresh);

  /// Stops watching the client. Does not disconnect it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _errorSub.cancel();
    await _connectionSub.cancel();
    await _failures.close();
  }

  Future<void> _connect(VobizCredentialsRequest request) async {
    if (_disposed) throw StateError('This credentials session was disposed');
    _busy = true;
    try {
      final CredentialConfig credentials;
      try {
        credentials = await _provider(request);
      } on VobizException {
        rethrow;
      } catch (e) {
        throw VobizCredentialsException(
            'The credentials provider failed: $e', cause: e);
      }
      if (credentials.username.trim().isEmpty || credentials.password.isEmpty) {
        throw const VobizCredentialsException(
            'The credentials provider returned an empty SIP username or password');
      }
      await client.connectWithCredentials(credentials);
    } finally {
      _busy = false;
    }
  }

  void _onConnection(ConnectionEvent event) {
    if (event.registrationState == RegistrationState.registered) {
      _consecutiveRefreshes = 0;
    }
  }

  void _onError(ErrorEvent event) {
    if (_disposed || _busy) return;
    if (event.code != VobizErrorCode.registrationFailed) return;
    if (_consecutiveRefreshes >= maxRefreshes) {
      _fail(VobizRegistrationException(
          'The registrar refused the credentials, also after asking the '
          'provider for new ones: ${event.message}'));
      return;
    }
    _consecutiveRefreshes++;
    _connect(VobizCredentialsRequest.rejected).catchError((Object e) {
      _fail(e is VobizException
          ? e
          : VobizCredentialsException('Re-registering failed: $e', cause: e));
    });
  }

  void _fail(VobizException e) {
    if (!_failures.isClosed) _failures.add(e);
  }
}
