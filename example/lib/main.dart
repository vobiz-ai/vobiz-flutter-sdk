import 'package:flutter/material.dart';

import 'src/app.dart';

/// Vobiz Playground for Flutter: the example app for the vobiz_webrtc SDK.
///
/// Sign in with Zero-Config Setup (your account's Auth ID and Auth Token) or
/// SIP Direct (an endpoint's username and password), then call with a caller
/// ID, custom SIP headers, recording and Dial-User, and transfer live calls —
/// the same options as the Vobiz WebRTC Playground on the web. No credentials
/// are built into the app.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PlaygroundApp());
}
