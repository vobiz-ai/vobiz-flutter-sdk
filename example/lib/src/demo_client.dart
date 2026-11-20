import 'package:flutter/foundation.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

/// Demo and test-only tools: Zero-Config sign-in (sends the account's Auth Token to a demo
/// server), typing account credentials for push sign-up, and the test-call tools.
///
/// On in debug builds (and tests). A release build has none of them unless it
/// is built with `--dart-define=VOBIZ_DEMO_TOOLS=true`.
const bool kDemoTools = bool.fromEnvironment('VOBIZ_DEMO_TOOLS', defaultValue: kDebugMode);

/// The Playground's SDK settings.
///
/// DEMO ONLY: Zero-Config Setup sends the account's Auth Token to the shared
/// rtc-demo webhook server. The SDK refuses that unless the client opts in
/// with `SdkConfig(unsafeDemoZeroConfig: true)`, which the Playground does
/// only with [demoTools]. A production app signs in with SIP credentials or
/// a short-lived token from its own backend instead.
SdkConfig playgroundConfig({bool demoTools = kDemoTools}) => SdkConfig(unsafeDemoZeroConfig: demoTools);

/// The Playground's VobizClient.
VobizClient createPlaygroundClient({bool demoTools = kDemoTools}) =>
    VobizClient(config: playgroundConfig(demoTools: demoTools));
