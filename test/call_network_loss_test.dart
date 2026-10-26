// #3: a call is never left 'active' with nobody able to end it. Signing out
// or disposing hangs up first; a dropped socket or lost media gets a grace
// period to recover, then the call ends as network_lost.
// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'call_harness.dart';

/// The far end's final response to the last [method] the client sent.
void answerLast(Harness h, String method, int code, String phrase) {
  final request =
      SipParser.parse(h.sent.lastWhere((m) => m.startsWith('$method ')));
  h.sip.debugReceive('SIP/2.0 $code $phrase\r\n'
      'Via: ${request.header('Via')}\r\n'
      'From: ${request.header('From')}\r\n'
      'To: ${request.header('To')}\r\n'
      'Call-ID: ${request.header('Call-ID')}\r\n'
      'CSeq: ${request.header('CSeq')}\r\nContent-Length: 0\r\n\r\n');
}

/// The network is back: the client registers again on a new connection.
void registerAgain(Harness h, [String user = 'play1']) {
  h.sent.clear();
  h.sip.register(user, 'secret');
  h.registered();
}

int countSent(Harness h, String method) =>
    h.firstLines.where((l) => l.startsWith('$method ')).length;

void main() {
  group('#3 zombie call: disconnect, dispose, socket drop, ICE loss', () {
    test('disconnect() during a connected call sends BYE before closing', () async {
      final h = await answeredCall();
      await h.client.disconnect();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'disconnected');
      await h.dispose();
    });

    test('dispose() during a connected call sends BYE and reports the end', () async {
      final h = await answeredCall();
      await h.dispose();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.events.map((e) => e.state), contains(CallStateStatus.ended));
    });

    test('disconnect() while a call is ringing here declines it (480)', () async {
      final h = Harness();
      h.invite('in-1');
      await h.client.disconnect();
      expect(h.sentStatus(480), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.sentRequest('BYE'), isFalse);
      await h.dispose();
    });

    test('a socket drop that does not recover ends the call as network_lost', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 50));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      // Media may still be flowing: the call is not ended at once.
      expect(h.client.callState, CallStateStatus.active);
      await h.settle();
      expect(h.events.last.reason, 'reconnecting');
      await h.settle(120);
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.errors.map((e) => e.code), contains('network_lost'));
      // A new call can be placed or received again.
      h.invite('in-2', branch: 'z9hG4bKb');
      expect(h.client.callState, CallStateStatus.incoming);
      await h.dispose();
    });

    test('a socket drop followed by re-registration keeps the call, and it can still be hung up', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 80));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      // What the reconnect does: close the old socket keeping the dialog, then
      // register again.
      h.sip.disconnect(keepCall: true);
      h.sip.register('play1', 'secret');
      h.registered();
      await h.settle();
      expect(h.events.last.reason, 'reconnected');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.active);
      await h.client.hangup();
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      expect(h.lastEnded.reason, 'Hung up');
      await h.dispose();
    });

    test('a socket drop while a call is still ringing ends it at once', () async {
      final h = Harness();
      h.invite('in-1');
      h.sip.onSocketError!('SIP socket error');
      await h.settle();
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      await h.dispose();
    });

    test('ICE failed on a connected call ends it as network_lost after the grace period', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 50));
      h.peer.ice(h.client.currentCallId!, RTCIceConnectionState.RTCIceConnectionStateFailed);
      expect(h.client.callState, CallStateStatus.active);
      await h.settle(120);
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('ICE disconnected then connected again keeps the call', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 80));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateConnected);
      await h.settle();
      expect(h.events.last.reason, 'reconnected');
      await h.settle(150);
      expect(h.client.callState, CallStateStatus.active);
      await h.dispose();
    });

    test('re-registering after a socket drop restarts ICE in a re-INVITE, and the call survives', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 200));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      h.sip.disconnect(keepCall: true);
      h.sip.register('play1', 'secret');
      h.registered();
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin']);
      final reInvite = h.sent.lastWhere((m) => m.startsWith('INVITE '));
      expect(reInvite, contains('Call-ID: in-1'));
      expect(reInvite, contains('a=ice-ufrag:new'));

      h.respondToReInvite(200, 'OK', body: 'v=0\r\nanswer');
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin', 'complete']);
      expect(h.sentRequest('ACK'), isTrue, reason: 'sent: ${h.firstLines}');

      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateConnected);
      await h.settle();
      expect(h.events.last.reason, 'reconnected');
      await h.settle(300);
      expect(h.client.callState, CallStateStatus.active);
      await h.dispose();
    });

    test('a refused ICE restart is rolled back, and the call ends as network_lost', () async {
      final h = await answeredCall(grace: const Duration(milliseconds: 100));
      final id = h.client.currentCallId!;
      h.peer.ice(id, RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      h.sip.disconnect(keepCall: true);
      h.sip.register('play1', 'secret');
      h.registered();
      await h.settle();
      h.respondToReInvite(488, 'Not Acceptable Here');
      await h.settle();
      expect(h.peer.iceRestarts, <String>['begin', 'abort']);
      expect(h.client.callState, CallStateStatus.active);
      await h.settle(200);
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'network_lost');
      await h.dispose();
    });
  });

  // Seen live 2026-10-26: airplane mode for 9 s plus 7 s for Android to bring
  // the network back. The grace ran out offline, the BYE never left, and the
  // callee's phone stayed on a silent, billed call.
  group('a BYE or CANCEL lost with the connection is sent again', () {
    Future<Harness> endedOffline() async {
      final h = await answeredCall(grace: const Duration(milliseconds: 50));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      await h.settle(120);
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.sentRequest('BYE'), isTrue, reason: 'sent: ${h.firstLines}');
      return h;
    }

    test('a call that ran out of grace offline sends its BYE again once registered', () async {
      final h = await endedOffline();
      registerAgain(h);
      expect(countSent(h, 'BYE'), 1, reason: 'sent: ${h.firstLines}');
      expect(h.sent.lastWhere((m) => m.startsWith('BYE ')), contains('Call-ID: in-1'));
      // Answered now: never sent again.
      answerLast(h, 'BYE', 200, 'OK');
      registerAgain(h);
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('a BYE that was answered is not sent again', () async {
      final h = await answeredCall();
      await h.client.hangup();
      answerLast(h, 'BYE', 200, 'OK');
      registerAgain(h);
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('a BYE refused with 481 (the far end already left) is not sent again', () async {
      final h = await endedOffline();
      registerAgain(h);
      answerLast(h, 'BYE', 481, 'Call/Transaction Does Not Exist');
      registerAgain(h);
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('a BYE is not sent for a different sign-in', () async {
      final h = await endedOffline();
      registerAgain(h, 'someone-else');
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('a BYE older than the resend window is dropped', () async {
      final h = await endedOffline();
      h.sip.pendingEndWindow = Duration.zero;
      await h.settle(5);
      registerAgain(h);
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });

    test('an unanswered BYE is sent again at most three times', () async {
      final h = await endedOffline();
      var resent = 0;
      for (var i = 0; i < 5; i++) {
        registerAgain(h);
        resent += countSent(h, 'BYE');
      }
      expect(resent, 3);
      await h.dispose();
    });

    test('a ringing outgoing call cut off by the network sends its CANCEL again', () async {
      final h = Harness();
      await h.dial();
      h.respond(180, 'Ringing');
      final invite =
          SipParser.parse(h.sent.lastWhere((m) => m.startsWith('INVITE ')));
      h.sip.onSocketError!('SIP socket closed unexpectedly');
      await h.settle();
      expect(h.lastEnded.reason, 'network_lost');
      expect(h.sentRequest('CANCEL'), isTrue, reason: 'sent: ${h.firstLines}');

      registerAgain(h);
      expect(countSent(h, 'CANCEL'), 1, reason: 'sent: ${h.firstLines}');
      final cancel =
          SipParser.parse(h.sent.lastWhere((m) => m.startsWith('CANCEL ')));
      // The INVITE's transaction: the registrar matches a CANCEL by these.
      final branch = RegExp(r'branch=([^;\s]+)');
      expect(branch.firstMatch(cancel.header('Via')!)!.group(1),
          branch.firstMatch(invite.header('Via')!)!.group(1));
      expect(cancel.header('Call-ID'), invite.header('Call-ID'));
      expect(cancel.header('CSeq')!.split(' ').first, invite.header('CSeq')!.split(' ').first);

      answerLast(h, 'CANCEL', 200, 'OK');
      registerAgain(h);
      expect(h.sentRequest('CANCEL'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });
  });
}
