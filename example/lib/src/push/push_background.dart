import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart' as ck;

import 'call_screen.dart';
import 'push_bridge_api.dart';
import 'push_call.dart';

/// Firebase runs this in a background isolate when a push arrives while the
/// app is in the background or has been swiped away. It must be a top-level
/// function.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final call = PushCall.fromData(message.data);
  if (call == null) return;
  if (call.kind == PushKind.callEnded) {
    await stopRinging(call);
    return;
  }
  if (call.isExpired) return;
  // With no app screen running, Accept and Decline are delivered to
  // [callScreenBackgroundHandler], so the bridge still hears about them.
  try {
    await ck.FlutterCallkitIncoming.onBackgroundMessage(callScreenBackgroundHandler);
  } on PlatformException catch (e) {
    debugPrint('Call screen background handler not registered: ${e.message}');
  }
  await showPushedCall(call);
}

/// The call screen runs this when Accept or Decline is tapped and no app
/// screen is listening (the app was closed). Accept also opens the app,
/// which signs in and answers.
@pragma('vm:entry-point')
Future<void> callScreenBackgroundHandler(ck.CallEvent event) async {
  final PushCall? call;
  final bool accepted;
  switch (event) {
    case ck.CallEventActionCallAccept(:final callKitParams):
      call = PushCall.fromExtra(callKitParams.extra);
      accepted = true;
    case ck.CallEventActionCallDecline(:final callKitParams):
      call = PushCall.fromExtra(callKitParams.extra);
      accepted = false;
    default:
      return;
  }
  if (call == null || call.isTest) return;
  try {
    await (accepted ? PushBridgeApi.accept(call) : PushBridgeApi.decline(call));
  } catch (e) {
    debugPrint('Could not tell the push server: $e');
  }
}

/// Rings [call] on the call screen, unless that call is ringing already:
/// shown by an earlier push, or by the app's SIP connection, which may have
/// received the INVITE first.
Future<void> showPushedCall(PushCall call) async {
  for (final active in await CallScreen.active()) {
    if (active.id == call.callId) return;
    final shownForSip = active.extra?['source'] == 'sip';
    final name = active.nameCaller ?? '';
    if (shownForSip && (samePhoneNumber(name, call.caller) || samePhoneNumber(name, call.callee))) {
      return;
    }
  }
  await CallScreen.showIncoming(
    id: call.callId,
    caller: call.isTest ? 'Test call' : call.caller,
    subtitle: call.isTest
        ? 'The push reached this phone. Nothing will connect.'
        : (call.callee.isEmpty ? 'Vobiz call' : 'Calling ${call.callee}'),
    extra: call.toExtra(),
  );
}

/// The bridge says [ended]'s caller is gone: stop the call screen ringing.
Future<void> stopRinging(PushCall ended) async {
  for (final active in await CallScreen.active()) {
    if (active.id == ended.callId) await CallScreen.end(active.id);
  }
}
