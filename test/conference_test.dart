// VobizConference: the app side of a conference. A fake conference server
// (package:http MockClient) answers the four routes; the call is the
// lifecycle harness's answered inbound call.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';

const _uuid = 'aaaaaaaa-1111-4222-8333-444444444444';

Map<String, Object?> _room({bool active = true, String addedStatus = 'dialing', bool muted = false}) =>
    <String, Object?>{
      'room': 'vc-aaaaaaaa-0a0b0c',
      'active': active,
      'participants': <Object?>[
        <String, Object?>{'id': 'p1', 'label': 'play1', 'you': true, 'role': 'host', 'status': 'joined', 'muted': false},
        <String, Object?>{'id': 'p2', 'label': '+918000000000', 'you': false, 'role': 'guest', 'status': 'joined', 'muted': false},
        <String, Object?>{'id': 'p3', 'label': '+919811111111', 'you': false, 'role': 'added', 'status': addedStatus, 'muted': muted},
      ],
    };

/// A fake conference server: records each request, answers with [reply].
class _Server {
  final List<http.Request> requests = <http.Request>[];
  http.Response Function(http.Request request) reply =
      (request) => http.Response(jsonEncode(_room()), 200);

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return reply(request);
  });

  Map<String, dynamic> body(int i) => jsonDecode(requests[i].body) as Map<String, dynamic>;
  List<String> get paths => requests.map((r) => r.url.path).toList();
}

void main() {
  late Harness h;
  late _Server server;
  late VobizConference conference;

  VobizConference make({
    String? Function()? callUuid,
    Duration poll = const Duration(seconds: 30),
    bool endCall = true,
  }) =>
      VobizConference(
        client: h.client,
        serverUrl: Uri.parse('https://bridge.example.test/'),
        headers: () => <String, String>{'Authorization': 'Bearer device.secret'},
        callUuid: callUuid ?? () => _uuid,
        httpClient: server.client,
        pollInterval: poll,
        endCallWithConference: endCall,
      );

  setUp(() async {
    h = await answeredCall();
    server = _Server();
    conference = make();
  });

  tearDown(() async {
    conference.dispose();
    await h.dispose();
  });

  test('add asks the server to dial the person into a conference of this call', () async {
    final state = await conference.add(number: '+919811111111', callerId: '+918000000001');

    expect(server.paths, <String>['/conference/add']);
    expect(server.requests.single.headers['Authorization'], 'Bearer device.secret');
    expect(server.body(0), <String, Object?>{
      'call_uuid': _uuid,
      'number': '+919811111111',
      'caller_id': '+918000000001',
    });
    expect(state.room, 'vc-aaaaaaaa-0a0b0c');
    expect(state.active, isTrue);
    expect(state.participants.map((p) => p.status), <VobizParticipantStatus>[
      VobizParticipantStatus.joined,
      VobizParticipantStatus.joined,
      VobizParticipantStatus.dialing,
    ]);
    expect(state.participants.first.isYou, isTrue);
    expect(conference.state.value, same(state));
  });

  test('a SIP user is sent as its bare username', () async {
    await conference.add(sipUser: 'sip:bob_1@registrar.vobiz.ai');
    expect(server.body(0), <String, Object?>{'call_uuid': _uuid, 'user': 'bob_1'});
  });

  test('add refuses a malformed target or a call that is not answered', () async {
    expect(() => conference.add(number: '98111'), throwsArgumentError);
    expect(() => conference.add(), throwsArgumentError);
    expect(() => conference.add(number: '+919811111111', sipUser: 'bob'), throwsArgumentError);
    expect(() => conference.add(number: '+919811111111', callerId: '8000'), throwsArgumentError);
    await h.client.hangup();
    await h.settle();
    expect(() => conference.add(number: '+919811111111'), throwsStateError);
    expect(server.requests, isEmpty);
  });

  test('without a CallUUID there is nothing to make a conference of', () async {
    conference.dispose();
    conference = make(callUuid: () => null);
    expect(() => conference.add(number: '+919811111111'), throwsStateError);
  });

  test('mute, hold, resume, remove and end name the participant and the call', () async {
    await conference.add(number: '+919811111111');
    await conference.mute('p3');
    await conference.hold('p3');
    await conference.resume('p3');
    await conference.unmute('p3');
    await conference.remove('p3');
    await conference.end();

    expect(server.paths.skip(1), <String>[
      ...List<String>.filled(5, '/conference/participant'),
      '/conference/end',
    ]);
    expect(<String?>[for (var i = 1; i <= 5; i++) server.body(i)['action'] as String?],
        <String>['mute', 'hold', 'resume', 'unmute', 'remove']);
    expect(server.body(1), <String, Object?>{'call_uuid': _uuid, 'participant_id': 'p3', 'action': 'mute'});
    expect(server.body(6), <String, Object?>{'call_uuid': _uuid});
  });

  test('a refusal throws, and still updates the state it carries', () async {
    await conference.add(number: '+919811111111');
    server.reply = (request) => http.Response(
        jsonEncode(<String, Object?>{'error': '+919811111111 is not in the room', 'conference': _room(addedStatus: 'failed')}),
        409);

    await expectLater(
      conference.mute('p3'),
      throwsA(isA<VobizException>()
          .having((e) => e.code, 'code', VobizErrorCode.conferenceFailed)
          .having((e) => e.statusCode, 'statusCode', 409)
          .having((e) => e.message, 'message', '+919811111111 is not in the room')),
    );
    expect(conference.state.value!.participants.last.status, VobizParticipantStatus.failed);
    expect(conference.state.value!.present, hasLength(2));
  });

  test('a server that cannot be reached is a conference failure', () async {
    server.reply = (request) => throw http.ClientException('connection refused');
    await expectLater(
      conference.add(number: '+919811111111'),
      throwsA(isA<VobizException>().having((e) => e.code, 'code', VobizErrorCode.conferenceFailed)),
    );
  });

  test('refresh is null when the call is not a conference', () async {
    server.reply = (request) => http.Response(jsonEncode(<String, Object?>{'error': 'No conference for this call'}), 404);
    expect(await conference.refresh(), isNull);
  });

  test('the state is refreshed while the conference is on, and cleared when the call ends', () async {
    conference.dispose();
    conference = make(poll: const Duration(milliseconds: 20));
    await conference.add(number: '+919811111111');
    server.reply = (request) => http.Response(jsonEncode(_room(addedStatus: 'joined')), 200);
    await h.settle(80);
    expect(server.paths.where((p) => p == '/conference/state'), isNotEmpty);
    expect(conference.state.value!.participants.last.status, VobizParticipantStatus.joined);

    await h.client.hangup();
    await h.settle(10);
    expect(conference.state.value, isNull);
    final polled = server.requests.length;
    await h.settle(80);
    expect(server.requests.length, polled, reason: 'no more polling once the call has ended');
  });

  test('polling stops once the server says the conference ended', () async {
    conference.dispose();
    conference = make(poll: const Duration(milliseconds: 20), endCall: false);
    await conference.add(number: '+919811111111');
    server.reply = (request) => http.Response(jsonEncode(_room(active: false)), 200);
    await h.settle(80);
    final polled = server.requests.length;
    await h.settle(80);
    expect(server.requests.length, polled);
    expect(conference.state.value!.active, isFalse);
    expect(h.client.callState, CallStateStatus.active, reason: 'endCallWithConference: false keeps the call');
  });

  test('when the server says the conference ended, the call is hung up', () async {
    conference.dispose();
    conference = make(poll: const Duration(milliseconds: 20));
    await conference.add(number: '+919811111111');
    server.reply = (request) => http.Response(jsonEncode(_room(active: false)), 200);
    await h.settle(80);
    expect(h.events.map((e) => e.state), contains(CallStateStatus.ended),
        reason: 'the room is gone, and a lost BYE must not leave the call up');
    expect(h.client.callState, isNot(CallStateStatus.active));
    expect(h.sent.any((m) => m.startsWith('BYE ')), isTrue);
    expect(conference.state.value, isNull);
  });

  test('end hangs up the call at once', () async {
    await conference.add(number: '+919811111111');
    server.reply = (request) => http.Response(jsonEncode(_room(active: false)), 200);
    await conference.end();
    await h.settle(10);
    expect(h.events.map((e) => e.state), contains(CallStateStatus.ended));
    expect(h.sent.where((m) => m.startsWith('BYE ')), hasLength(1), reason: 'one BYE, not one per signal');
  });

  test('participants read every status the server sends', () {
    final state = VobizConferenceState.fromJson(<String, dynamic>{
      'room': 'r',
      'participants': <Object?>[
        for (final s in <String>['connecting', 'dialing', 'joined', 'on_hold', 'left', 'failed', 'something-new'])
          <String, Object?>{'id': s, 'label': s, 'status': s},
      ],
    });
    expect(state.participants.map((p) => p.status), <VobizParticipantStatus>[
      VobizParticipantStatus.connecting,
      VobizParticipantStatus.dialing,
      VobizParticipantStatus.joined,
      VobizParticipantStatus.onHold,
      VobizParticipantStatus.left,
      VobizParticipantStatus.failed,
      VobizParticipantStatus.left,
    ]);
    expect(state.present.map((p) => p.id), <String>['connecting', 'dialing', 'joined', 'on_hold']);
    expect(() => VobizConferenceState.fromJson(<String, dynamic>{'error': 'x'}), throwsFormatException);
  });
}
