import 'package:vobiz_webrtc/vobiz_webrtc.dart';

/// The Playground's VobizClient.
///
/// DEMO ONLY: Zero-Config Setup sends the account's Auth Token to the shared
/// rtc-demo webhook server. The SDK refuses that unless the client opts in
/// with `SdkConfig(unsafeDemoZeroConfig: true)`. A production app signs in
/// with SIP credentials or a short-lived token from its own backend instead.
VobizClient createPlaygroundClient() => VobizClient(
      config: const SdkConfig(unsafeDemoZeroConfig: true),
    );
