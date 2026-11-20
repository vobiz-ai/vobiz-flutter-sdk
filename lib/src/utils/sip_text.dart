final RegExp _controlCharacter = RegExp(r'[\x00-\x1f\x7f]');

/// Whether [value] holds a control character (CR and LF among them) or DEL.
/// Written into a SIP message it would end the header line, or start a new
/// header the SDK never meant to send.
bool hasControlCharacter(String value) => _controlCharacter.hasMatch(value);
