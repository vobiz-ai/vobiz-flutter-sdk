// Call control: a stale id cannot strand a ringing call, a refused or failed
// hold puts things back, a 481 ends a call the far end no longer has, a
// refused re-INVITE is ACKed, a hang-up while the INVITE is being built sends
// nothing, and currentCall and call events say what is true.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'media_fakes.dart' show MediaHarness, audioSdp;
import 'sip_test_support.dart';

const String _challenge = 'Proxy-Authenticate: Digest realm="registrar.vobiz.ai", nonce="n1", qop="auth"';

/// The far end's BYE for the inbound call [callId].
String _bye(String callId) => 'BYE sip:abcd@203.0.113.5;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=z9hG4bKbye\r\n'
    'From: <sip:+918000000000@10.0.2.9>;tag=ms\r\n'
    'To: <sip:play1@registrar.vobiz.ai>;tag=x\r\n'
    'Call-ID: $callId\r\nCSeq: 102 BYE\r\nContent-Length: 0\r\n\r\n';

void main() {
  group('acceptCall', () {
    test('with an id that is not the ringing call does nothing; the call can still be answered', () async {
      final h = Harness();
      h.invite('in-1');
      await h.client.acceptCall('in_0_an_older_call');
      expect(h.client.callState, CallStateStatus.incoming);
      expect(h.sentStatus(200), isFalse);
      await h.client.acceptCall();
      expect(h.client.callState, CallStateStatus.active);
      expect(h.sentStatus(200), isTrue);
      await h.dispose();
    });
  });

  group('hold and resume', () {
    test('building the hold offer fails: rolled back, hold_failed, and the call goes on', () async {
      final h = await answeredCall();
      h.peer.beginHoldError = StateError('have-remote-offer');
      await expectLater(h.client.hold(),
          throwsA(isA<VobizException>().having((e) => e.code, 'code', 'hold_failed')));
      expect(h.peer.holds, <String>['begin:hold', 'abort'], reason: 'the microphone and direction are put back');
      expect(h.client.callState, CallStateStatus.active);
      expect(h.sentRequest('INVITE'), isFalse);
      // Nothing is left in progress: the next hold goes ahead.
      h.peer.beginHoldError = null;
      final holding = h.client.hold();
      await h.settle();
      h.respondToReInvite(200, 'OK', body: 'v=0\r\na=recvonly');
      await holding;
      expect(h.client.callState, CallStateStatus.held);
      await h.dispose();
    });

    test('a 481 to the hold re-INVITE ends the call without a BYE, and hold still fails', () async {
      final h = await answeredCall();
      final holding = h.client.hold();
      await h.settle();
      h.respondToReInvite(481, 'Call/Transaction Does Not Exist');
      await expectLater(
          holding,
          throwsA(isA<VobizException>()
              .having((e) => e.code, 'code', 'hold_failed')
              .having((e) => e.statusCode, 'statusCode', 481)));
      await h.settle();
      expect(h.client.callState, CallStateStatus.idle);
      expect(h.lastEnded.reason, 'The call no longer exists');
      expect(h.sentRequest('BYE'), isFalse, reason: 'sent: ${h.firstLines}');
      await h.dispose();
    });
  });

  group('our own re-INVITE refused', () {
    late List<String> sent;
    late SIPService s;

    setUp(() {
      sent = <String>[];
      s = sipService(sent);
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      sent.clear();
    });

    test('a 488 is ACKed on the re-INVITE\'s branch and CSeq', () async {
      final answer = s.reInvite('v=0\r\na=sendonly');
      final reInvite = sent.single;
      s.debugReceive(respond(reInvite, 488, 'Not Acceptable Here'));
      await expectLater(answer, throwsA(isA<SipRequestFailed>()));
      final ack = sent.last;
      expect(firstLine(ack), startsWith('ACK '));
      expect(branchOf(ack), branchOf(reInvite));
      expect(headerOf(ack, 'CSeq'), '${headerOf(reInvite, 'CSeq').split(' ').first} ACK');
      expect(headerOf(ack, 'Route'), headerOf(reInvite, 'Route'));
    });

    test('a 407 is ACKed before the re-INVITE is sent again with credentials', () {
      unawaited(s.reInvite('v=0\r\na=sendonly').catchError((Object _) => ''));
      final reInvite = sent.single;
      s.debugReceive(respond(reInvite, 407, 'Proxy Authentication Required', headers: <String>[_challenge]));
      expect(methods(sent), <String>['INVITE', 'ACK', 'INVITE']);
      expect(branchOf(sent[1]), branchOf(reInvite));
      expect(headerOf(sent.last, 'Proxy-Authorization'), startsWith('Digest '));
    });
  });

  test('a 481 to a DTMF INFO ends the call the far end no longer has', () {
    final sent = <String>[];
    final ended = <String?>[];
    final s = sipService(sent)..onCallEnded = ended.add;
    s.debugReceive(inboundInvite());
    s.answer('v=0');
    sent.clear();
    expect(s.sendDtmf('1'), isTrue);
    s.debugReceive(respond(sent.single, 481, 'Call/Transaction Does Not Exist'));
    expect(ended, <String?>['The call no longer exists']);
    expect(s.hasActiveDialog, isFalse);
    expect(methods(sent), <String>['INFO'], reason: 'no BYE for a call that is gone');
  });

  group('a late INVITE', () {
    test('with a To tag for a call that has ended gets 481 and does not ring', () {
      final sent = <String>[];
      final rang = <String>[];
      final s = sipService(sent)..onIncomingCall = ((caller, _, __) => rang.add(caller));
      s.debugReceive(inboundInvite());
      s.answer('v=0');
      s.hangup();
      rang.clear();
      sent.clear();
      // A re-INVITE that crossed the BYE.
      s.debugReceive(inboundInvite(cseq: 102, branch: 'z9hG4bKre')
          .replaceFirst('To: <sip:play1@registrar.vobiz.ai>', 'To: <sip:play1@registrar.vobiz.ai>;tag=ours'));
      expect(firstLine(sent.single), 'SIP/2.0 481 Call/Transaction Does Not Exist');
      expect(rang, isEmpty);
      // A new call (no To tag) still rings.
      s.debugReceive(inboundInvite(callId: 'in-call-2', branch: 'z9hG4bKnew'));
      expect(rang, hasLength(1));
    });
  });

  test('makeCall hung up during its last await sends no INVITE and leaves the client idle', () async {
    final h = Harness();
    h.peer.localDescriptionGate = Completer<RTCSessionDescription?>();
    final placing = h.client.makeCall('+919876543210');
    await h.settle(20);
    await h.client.hangup();
    h.peer.localDescriptionGate!.complete(RTCSessionDescription('v=0\r\nlocal', 'offer'));
    await placing;
    expect(h.sentRequest('INVITE'), isFalse, reason: 'sent: ${h.firstLines}');
    expect(h.client.callState, CallStateStatus.idle);
    // The line is free: the next call goes out.
    h.peer.localDescriptionGate = null;
    await h.dial();
    expect(h.sentRequest('INVITE'), isTrue);
    await h.client.hangup();
    await h.dispose();
  });

  group('call events', () {
    test('ended carries the SIP Call-ID when the far end hangs up', () async {
      final h = await answeredCall();
      h.sip.debugReceive(_bye('in-1'));
      await h.settle();
      expect(h.lastEnded.sipCallId, 'in-1');
      await h.dispose();
    });

    test('failed and ended carry it when an outbound call is refused', () async {
      final h = Harness();
      await h.dial();
      final callId = SipParser.parse(h.sent.lastWhere((m) => m.startsWith('INVITE '))).header('Call-ID');
      h.respond(486, 'Busy Here');
      await h.settle();
      expect(h.events.lastWhere((e) => e.state == CallStateStatus.failed).sipCallId, callId);
      expect(h.lastEnded.sipCallId, callId);
      await h.dispose();
    });
  });

  group('currentCall and mute', () {
    late SIPService sip;
    late VobizClient client;
    late MediaHarness media;

    setUp(() async {
      final sent = <String>[];
      media = MediaHarness();
      sip = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai')..debugOnSend = sent.add;
      client = VobizClient.withServices(sip: sip, peer: media.service);
      sip.register('play1', 'secret');
      sip.debugReceive(respond(sent.last, 200, 'OK'));
      sip.debugReceive(inboundInvite(sdp: audioSdp));
    });

    tearDown(() async {
      sip.unregisterTimeout = const Duration(milliseconds: 10);
      await client.dispose();
    });

    test('DTMF is not offered while an outbound call rings, only once a call is connected', () async {
      await client.rejectCall(); // the inbound call from setUp
      await client.makeCall('+919876543210');
      expect(client.callState, CallStateStatus.ringing);
      expect(client.currentCall!.actions.canSendDtmf, isFalse, reason: 'sendDtmf refuses it now');
      await client.hangup();
      sip.debugReceive(inboundInvite(callId: 'in-call-2', branch: 'z9hG4bKsecond', sdp: audioSdp));
      await client.acceptCall();
      expect(client.currentCall!.actions.canSendDtmf, isTrue);
    });

    test('muted and speakerEnabled say what is true', () async {
      await client.acceptCall();
      expect(client.currentCall!.muted, isFalse);
      await client.mute();
      expect(client.currentCall!.muted, isTrue);
      expect(client.currentCall!.speakerEnabled, client.isSpeakerOn);
    });

    test('mute with an id that is not the current call does nothing', () async {
      await client.acceptCall();
      await client.mute('in_0_an_older_call');
      expect(client.isMuted, isFalse);
      await client.mute(client.currentCallId);
      expect(client.isMuted, isTrue);
      await client.unmute('in_0_an_older_call');
      expect(client.isMuted, isTrue);
    });
  });
}
