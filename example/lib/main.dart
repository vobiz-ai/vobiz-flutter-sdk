import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/push/push_service.dart';

/// Vobiz Playground for Flutter: the example app for the vobiz_webrtc SDK.
///
/// Sign in with Zero-Config Setup (your account's Auth ID and Auth Token) or
/// SIP Direct (an endpoint's username and password), then call with a caller
/// ID, custom SIP headers, recording and Dial-User, and transfer live calls —
/// the same options as the Vobiz WebRTC Playground on the web. No credentials
/// are built into the app.
///
/// With the push bridge (example/push_bridge) and Firebase set up, calls to
/// your Vobiz number also ring the phone when the app is in the background or
/// has been swiped away.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final push = await PushService.start();
  runApp(PlaygroundApp(push: push));
}
