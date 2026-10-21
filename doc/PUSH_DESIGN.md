# Incoming-call push: design note

Status: **design**. Only the plugin-free payload API below ships today.

## The problem

The SDK registers over a WebSocket. When Android or iOS suspends or kills the app, the
socket closes and Vobiz drops the registration, so the endpoint cannot be rung. Ringing
a closed app takes three pieces:

1. Something that sees the inbound call while the endpoint is offline and sends a push.
2. A native call screen (Android `ConnectionService` / full-screen notification, iOS
   CallKit) that rings while the app starts.
3. The app signing back in and matching the SIP INVITE that follows to the screen
   already showing.

Today (1) is the single-tenant example bridge in `example/push_bridge`, and (2) and (3)
are about 1,000 lines in `example/lib`. A customer has to copy all of it.

## What ships now

`VobizIncomingPush` (in the SDK, no plugin dependency):

```dart
final push = VobizIncomingPush.tryParse(remoteMessage.data);
if (push == null || push.isExpired()) return;
// show your call screen with push.caller …
// after sign-in, when the INVITE arrives:
client.callEvents.listen((e) {
  if (e.state == CallStateStatus.incoming &&
      push.matchesIncomingCall(headers: e.headers, from: e.remoteIdentity)) {
    client.acceptCall(); // if the user already tapped Accept
  }
});
```

It reads the payload the reference bridge sends (`type`, `call_id`, `caller`,
`callee`, `expires_at`, …) and matches the INVITE by its `PushRef` SIP header, falling
back to the caller's number.

## What the SDK will expose

```dart
// 1. Tell Vobiz (or your backend) where to push for this endpoint.
await client.registerPushToken(token, platform: VobizPushPlatform.fcm /* or apnsVoip */);
await client.unregisterPushToken();

// 2. Hand a push to the SDK. It signs in through the app's credentials provider
//    (cached credentials, no Auth Token, no rotation), waits for the INVITE that
//    matches the push, and reports it as a normal incoming call.
final call = await client.handleIncomingPush(payload, credentials: provider);

// 3. Call-screen hooks, so any call-screen plugin can drive the SDK:
client.reportCallScreenAccepted(push);   // answer as soon as the INVITE arrives
client.reportCallScreenDeclined(push);   // reject the INVITE, or tell the sender
Stream<VobizPushCallState> client.pushCallStates; // ringing / answered / missed / ended
```

Design rules:

- The SDK stays free of Firebase, CallKit and ConnectionService plugins. Native call
  UI lives in an optional companion package (`vobiz_webrtc_callkit`) or in the app.
- Sign-in on wake uses the credentials provider with `VobizCredentialsRequest.signIn`,
  so it reuses cached per-user credentials and never rotates them (issue #14).
- Correlation is by an opaque push reference carried both in the push and on the
  INVITE; caller-number matching is only the fallback.

## Platform work this depends on

| Need | Owner |
|---|---|
| Vobiz-side push: when an endpoint with a push token is offline, push it and hold the call until it registers (the Console already lists "Push Notifications" tokens) | Vobiz platform |
| An API to attach a push token to an endpoint | Vobiz platform |
| A documented SIP header that carries the push reference onto the INVITE | Vobiz platform |
| Until then: a multi-tenant reference push server (the example bridge is single-tenant) | SDK team |

## iOS (remaining)

Not implemented, because it needs native Swift that has to be verified on a device:

- `PKPushRegistry` for VoIP pushes, and `CXProvider.reportNewIncomingCall`
  **synchronously** inside the PushKit callback (iOS 13+ terminates the app
  otherwise).
- APNs VoIP sending in the push server (the bridge sends FCM with Android options only).
- Then, and only then, the `voip` background mode in `Info.plist`.

Until this lands, iOS rings only while the app is in the foreground, and
PLATFORM_SETUP.md says so.
