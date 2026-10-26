import 'dart:convert';

import '../errors/vobiz_exception.dart';

/// A Vobiz access token (JWT): who it signs in as, until when, and what it
/// allows.
///
/// Your backend mints it with `POST /api/v1/Account/{auth_id}/JWT/Token/`
/// (see CREDENTIALS.md), so the account Auth Token never reaches the device.
/// The SDK decodes it only to learn the identity, the expiry and the grants;
/// it never checks the signature. The registrar does that on every REGISTER
/// and INVITE.
///
/// ```json
/// {"iss": "MA_XXXXXXXX", "sub": "agent42", "nbf": 1790000000, "exp": 1790003600,
///  "app": "12345678901234567",
///  "per": {"voice": {"incoming_allow": true, "outgoing_allow": true}}}
/// ```
class VobizAccessToken {
  const VobizAccessToken._({
    required this.token,
    required this.accountId,
    required this.subject,
    required this.appId,
    required this.notBefore,
    required this.expiresAt,
    required this.incomingAllowed,
    required this.outgoingAllowed,
    required this.sipUsername,
  });

  /// Decodes [token].
  ///
  /// Throws [VobizAccessTokenException] (`INVALID_ACCESS_TOKEN`, 10001) unless
  /// it is a JWT with the claims a Vobiz token carries: `iss` (the Auth ID),
  /// `nbf` and `exp` (Unix seconds) and, when present, `sub` and `app` as
  /// strings and `per.voice.incoming_allow` / `outgoing_allow` as booleans.
  /// These are the checks the web SDK makes before it signs in.
  factory VobizAccessToken.parse(String token) {
    final raw = token.trim();
    final parts = raw.split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
      throw const VobizAccessTokenException(
          'Not an access token: a JWT has three dot-separated parts',
          tokenError: VobizAccessTokenException.invalidToken);
    }
    final Object? claims;
    try {
      claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    } catch (e) {
      throw VobizAccessTokenException('The access token\'s claims are not JSON',
          tokenError: VobizAccessTokenException.invalidToken, cause: e);
    }
    if (claims is! Map) {
      throw const VobizAccessTokenException('The access token\'s claims are not a JSON object',
          tokenError: VobizAccessTokenException.invalidToken);
    }
    Never invalid(String why) => throw VobizAccessTokenException('Invalid access token: $why',
        tokenError: VobizAccessTokenException.invalidToken);

    final iss = claims['iss'];
    if (iss is! String || iss.trim().isEmpty) invalid('no iss (the account Auth ID)');
    final nbf = claims['nbf'];
    if (nbf is! num) invalid('nbf must be a number of seconds');
    final exp = claims['exp'];
    if (exp is! num) invalid('exp must be a number of seconds');
    final sub = claims['sub'];
    if (sub != null && sub is! String) invalid('sub must be a string');
    final app = claims['app'];
    if (app != null && app is! String) invalid('app must be a string');

    bool? incoming;
    bool? outgoing;
    final per = claims['per'];
    if (per != null) {
      if (per is! Map) invalid('per must be an object');
      final voice = per['voice'];
      if (voice != null) {
        if (voice is! Map) invalid('per.voice must be an object');
        final i = voice['incoming_allow'];
        final o = voice['outgoing_allow'];
        if (i != null && i is! bool) invalid('per.voice.incoming_allow must be true or false');
        if (o != null && o is! bool) invalid('per.voice.outgoing_allow must be true or false');
        incoming = i as bool?;
        outgoing = o as bool?;
      }
    }

    final accountId = iss.trim();
    final subject = sub is String && sub.trim().isNotEmpty ? sub.trim() : null;
    return VobizAccessToken._(
      token: raw,
      accountId: accountId,
      subject: subject,
      appId: app is String && app.trim().isNotEmpty ? app.trim() : null,
      notBefore: _fromSeconds(nbf),
      expiresAt: _fromSeconds(exp),
      incomingAllowed: incoming,
      outgoingAllowed: outgoing,
      // The registrar knows a token user as "<sub>_<iss>". Without a sub the
      // web SDK makes up a one-off name the same way.
      sipUsername: subject != null
          ? '${subject}_$accountId'
          : 'puser${DateTime.now().millisecondsSinceEpoch}jt_$accountId',
    );
  }

  /// The token itself, sent as the `X-Vobiz-Jwt` header. Never log it: it
  /// signs in as [sipUsername] until [expiresAt].
  final String token;

  /// `iss`: the Auth ID of the account (or sub-account) that minted it.
  final String accountId;

  /// `sub`: your user's identity, as your backend put it in the token.
  final String? subject;

  /// `app`: the application whose Answer URL handles this user's outbound
  /// calls. Without it the account's default application does.
  final String? appId;

  /// `nbf`: the token is refused before this.
  final DateTime notBefore;

  /// `exp`: the token is refused from this moment on.
  final DateTime expiresAt;

  /// `per.voice.incoming_allow`, when the token says.
  final bool? incomingAllowed;

  /// `per.voice.outgoing_allow`, when the token says.
  final bool? outgoingAllowed;

  /// The SIP user this token registers as: `<sub>_<iss>`, the name to put in
  /// `<Dial><User>sip:<sipUsername>@registrar.vobiz.ai</User></Dial>` to ring
  /// this user.
  final String sipUsername;

  /// Whether the token allows outgoing calls (`outgoing_allow: true`).
  bool get canCallOut => outgoingAllowed == true;

  /// Whether the token allows incoming calls (`incoming_allow: true`). The
  /// SDK only reports it; the platform decides.
  bool get canReceiveCalls => incomingAllowed == true;

  /// Whether [expiresAt] has passed by this device's clock.
  bool isExpired([DateTime? now]) => !(now ?? DateTime.now()).isBefore(expiresAt);

  /// How long until [expiresAt] by this device's clock (negative once past).
  Duration timeLeft([DateTime? now]) => expiresAt.difference(now ?? DateTime.now());

  static DateTime _fromSeconds(num seconds) =>
      DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);

  // Never the token itself: it is a credential.
  @override
  String toString() => 'VobizAccessToken($sipUsername, expires ${expiresAt.toIso8601String()})';
}
