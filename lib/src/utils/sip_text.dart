/// A phone number in E.164 format: a plus and 7 to 15 digits. The one rule
/// for a caller ID, a transfer number and a conference number.
final RegExp e164Number = RegExp(r'^\+\d{7,15}$');

/// A SIP endpoint username as a transfer or a conference names its target:
/// letters, digits and `_ . - +`, at most 120.
final RegExp sipUserName = RegExp(r'^[A-Za-z0-9_.\-+]{1,120}$');

final RegExp _controlCharacter = RegExp(r'[\x00-\x1f\x7f]');

/// Whether [value] holds a control character (CR and LF among them) or DEL.
/// Written into a SIP message it would end the header line, or start a new
/// header the SDK never meant to send.
bool hasControlCharacter(String value) => _controlCharacter.hasMatch(value);
