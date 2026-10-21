/// Custom SIP header rules for outbound calls, transfers and incoming calls.
///
/// The checks mirror the Vobiz web SDK (`vobiz-webrtc-sdk`, `utils/headers.ts`)
/// exactly, so a header accepted here is one the platform accepts. Vobiz
/// delivers every `X-VH-` header on an INVITE to the answer webhook as a
/// top-level parameter, which is how the webhook server learns the caller ID,
/// whether to record, and which endpoint to ring.
///
/// ```dart
/// final check = VobizSipHeaders.check({'X-VH-Order-Id': 'A1234'});
/// if (!check.isValid) print(check.errors);
/// ```
class VobizSipHeaders {
  VobizSipHeaders._();

  /// Every custom header name starts with this.
  static const String prefix = 'X-VH-';

  /// The one non-`X-VH-` header the platform accepts, with a longer value limit.
  static const String jwt = 'X-Vobiz-JWT';

  /// `true` records the whole call: the webhook server answers with a session
  /// `<Record>`, and the file is listed by the server once the call ends.
  static const String record = 'X-VH-Record';

  /// Rings a SIP endpoint instead of the dialled number. The value is the
  /// endpoint's username. A SIP endpoint can only be reached as the target of
  /// `<Dial><User>`, so dial any routable number and name the endpoint here.
  static const String dialUser = 'X-VH-DialUser';

  /// The caller ID (E.164) the webhook server presents on the outbound leg.
  static const String callerId = 'X-VH-Caller-ID';

  static final RegExp _nameSuffix = RegExp(r'^[a-zA-Z0-9-]{1,19}$');
  static final RegExp _value = RegExp(r'^[a-z0-9A-Z_\-+()%.]{1,120}$');
  static final RegExp _jwtValue = RegExp(r'^[a-z0-9A-Z_\-+()%.]{1,500}$');
  static final RegExp _xmlName = RegExp(r'^[a-zA-Z0-9]+$');

  /// Whether [name] is the JWT header, which has a longer value limit.
  static bool isJwt(String name) => name.trim().toUpperCase() == jwt.toUpperCase();

  /// Why [name] is rejected, or null when the platform accepts it.
  static String? validateName(String name) {
    final key = name.trim();
    if (key.isEmpty) return 'Name is required';
    if (isJwt(key)) return null;
    if (!key.toUpperCase().startsWith(prefix.toUpperCase())) {
      return 'Must start with $prefix';
    }
    if (!_nameSuffix.hasMatch(key.substring(prefix.length))) {
      return 'After $prefix use 1-19 letters, digits or hyphens';
    }
    return null;
  }

  /// Why [value] is rejected for a header called [name], or null when valid.
  static String? validateValue(String name, String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Value is required';
    final jwtHeader = isJwt(name);
    if (!(jwtHeader ? _jwtValue : _value).hasMatch(v)) {
      return 'Only A-Z a-z 0-9 _ - + ( ) % . and max ${jwtHeader ? 500 : 120} '
          'chars (no spaces)';
    }
    return null;
  }

  /// Checks [headers] and splits them into the ones the platform accepts and
  /// a readable reason for each one it does not.
  ///
  /// The web SDK silently drops an invalid header, so a call would go out
  /// without it and nothing would say why. Calling code should refuse to dial
  /// while [HeaderCheck.errors] is not empty.
  static HeaderCheck check(Map<String, String> headers) {
    final valid = <String, String>{};
    final errors = <String>[];
    final seen = <String>{};
    headers.forEach((rawName, rawValue) {
      final name = rawName.trim();
      final value = rawValue.trim();
      final nameError = validateName(name);
      if (nameError != null) {
        errors.add('${name.isEmpty ? '(unnamed)' : name}: $nameError');
        return;
      }
      final valueError = validateValue(name, value);
      if (valueError != null) {
        errors.add('$name: $valueError');
        return;
      }
      // SIP header names are case-insensitive, so X-VH-a and X-VH-A collide.
      if (!seen.add(name.toUpperCase())) {
        errors.add('$name: duplicate header, keeping the first one');
        return;
      }
      valid[name] = value;
    });
    return HeaderCheck(valid, errors);
  }

  /// The custom headers in [source] that pass the rules: what the web SDK
  /// reports as an incoming call's extra headers.
  static Map<String, String> pick(Map<String, String> source) {
    final found = <String, String>{};
    source.forEach((name, value) {
      if (validateName(name) == null && validateValue(name, value) == null) {
        found[name] = value.trim();
      }
    });
    return found;
  }

  /// The value for a `sipHeaders` attribute on `<Dial>`, `<Number>` or `<User>`.
  ///
  /// Vobiz XML takes comma-separated `name=value` pairs and re-applies the
  /// `X-VH-` prefix itself, so the prefix is stripped here. The XML layer only
  /// allows `A-Za-z0-9` in names, which is stricter than the SDK: values are
  /// URL-encoded and headers with other characters in their names are
  /// returned in [XmlSipHeaders.skipped] rather than sent.
  static XmlSipHeaders toXml(Map<String, String> headers) {
    final pairs = <String>[];
    final skipped = <String>[];
    headers.forEach((name, value) {
      final bare = name.replaceFirst(RegExp('^x-vh-', caseSensitive: false), '');
      if (!_xmlName.hasMatch(bare)) {
        skipped.add(name);
        return;
      }
      pairs.add('$bare=${Uri.encodeComponent(value)}');
    });
    return XmlSipHeaders(pairs.join(','), skipped);
  }
}

/// The result of [VobizSipHeaders.check].
class HeaderCheck {
  const HeaderCheck(this.valid, this.errors);

  /// Headers the platform accepts, ready to send.
  final Map<String, String> valid;

  /// One readable reason per rejected header.
  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

/// The result of [VobizSipHeaders.toXml].
class XmlSipHeaders {
  const XmlSipHeaders(this.value, this.skipped);

  /// The attribute value, for example `OrderId=A1234,Plan=gold`.
  final String value;

  /// Headers left out because their names are not plain letters and digits.
  final List<String> skipped;
}
