// VobizConference across call boundaries: a reply that arrives after its
// call ended must not act on the next call, refresh() takes over a
// conference another object started, and the CallUUID sent by default is
// the one the client reports for the call.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

import 'call_harness.dart';
import 'sip_test_support.dart' show inboundInvite;

Map<String, Object?> _room({bool active = true}) => <String, Object?>{
      'room': 'vc-aaaaaaaa-0a0b0c',
      'active': active,
      'participants': <Object?>[
        <String, Object?>{'id': 'p1', 'label': 'play1', 'you': true, 'role': 'host', 'status': 'joined'},
        <String, Object?>{'id': 'p3', 'label': '+919811111111', 'role': 'added', 'status': 'dialing'},
      ],
    };

/// A conference server whose next reply can be held back with [gate].
class _Server {
  final List<http.Request> requests = <http.Request>[];
  Completer<void>? gate;
  Map<String, Object?> Function() room = _room;

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final wait = gate;
    if (wait != null) {
      gate = null;
      await wait.future;
    }
    return http.Response(jsonEncode(room()), 200);
  });

  List<String> get paths => requests.map((r) => r.url.path).toList();
  Map<String, dynamic> body(int i) => jsonDecode(requests[i].body) as Map<String, dynamic>;
}

void main() {
  late Harness h;
  late _Server server;
  var uuid = 'uuid-call-1';

  VobizConference make({bool overrideUuid = true, Duration poll = const Duration(milliseconds: 20)}) =>
      VobizConference(
        client: h.client,
        serverUrl: Uri.parse('https://bridge.example.test'),
        callUuid: overrideUuid ? () => uuid : null,
        httpClient: server.client,
        pollInterval: poll,
      );

  Future<void> secondCall() async {
    uuid = 'uuid-call-2';
    h.invite('in-2', branch: 'z9hG4bKb');
    await h.client.acceptCall();
    expect(h.client.callState, CallStateStatus.active);
  }

  setUp(() async {
    uuid = 'uuid-call-1';
    h = await answeredCall();
    server = _Server();
  });

  tearDown(() => h.dispose());

  test('a call that ends while add is in flight leaves no conference for the next call', () async {
    final conference = make();
    final gate = server.gate = Completer<void>();
    final adding = conference.add(number: '+919811111111');
    await h.settle();
    await h.client.hangup();
    await h.settle();
    gate.complete();
    await adding;
    await h.settle(80);
    expect(server.paths, <String>['/conference/add'], reason: 'no poll for the ended call');
    expect(conference.state.value, isNull);

    await secondCall();
    await conference.add(number: '+919811111111');
    expect(server.body(1)['call_uuid'], 'uuid-call-2',
        reason: 'the ended call\'s id used to be sent again');
    conference.dispose();
  });

  test('dispose while add is in flight starts no polling', () async {
    final conference = make();
    final gate = server.gate = Completer<void>();
    final adding = conference.add(number: '+919811111111');
    await h.settle();
    conference.dispose();
    gate.complete();
    await adding;
    await h.settle(80);
    expect(server.requests, hasLength(1), reason: 'a poll started after dispose never stopped');
  });

  test('an end() answered after its call ended does not hang up the next call', () async {
    final conference = make(poll: const Duration(minutes: 1));
    await conference.add(number: '+919811111111');
    final gate = server.gate = Completer<void>();
    final ending = conference.end();
    await h.settle();
    await h.client.hangup();
    await h.settle();
    await secondCall();
    server.room = () => _room(active: false);
    gate.complete();
    await ending;
    await h.settle(10);
    expect(h.client.callState, CallStateStatus.active);
    conference.dispose();
  });

  test('refresh() takes over a conference another object started for this call', () async {
    final conference = make();
    final state = await conference.refresh();
    expect(state?.active, isTrue);
    await conference.mute('p3');
    expect(server.body(1), <String, Object?>{
      'call_uuid': 'uuid-call-1',
      'participant_id': 'p3',
      'action': 'mute',
    });
    await h.settle(80);
    expect(server.paths.where((p) => p == '/conference/state').length, greaterThan(1),
        reason: 'the state is refreshed from then on');
    conference.dispose();
  });

  test('refresh() does not take over a conference that has ended', () async {
    final conference = make();
    server.room = () => _room(active: false);
    await conference.refresh();
    expect(() => conference.mute('p3'), throwsStateError);
    conference.dispose();
  });

  test('by default the CallUUID is the one the client reports, lower-cased', () async {
    await h.client.hangup();
    await h.settle();
    h.sip.debugReceive(inboundInvite(callId: 'in-3', branch: 'z9hG4bKc').replaceFirst(
        'Contact:', 'X-Calluuid: AAAAAAAA-1111-4222-8333-444444444444\r\nContact:'));
    await h.client.acceptCall();
    expect(h.client.callUuid, 'AAAAAAAA-1111-4222-8333-444444444444');
    final conference = make(overrideUuid: false, poll: const Duration(minutes: 1));
    await conference.add(number: '+919811111111');
    expect(server.body(0)['call_uuid'], 'aaaaaaaa-1111-4222-8333-444444444444');
    conference.dispose();
  });

  test('numbers follow the transfer rule: a plus and 7 to 15 digits', () async {
    final conference = make(poll: const Duration(minutes: 1));
    expect(() => conference.add(number: '+123456'), throwsArgumentError);
    expect(() => conference.add(number: '+1234567', callerId: '+123456'), throwsArgumentError);
    await conference.add(number: '+1234567', callerId: '+1234567');
    expect(server.body(0)['number'], '+1234567');
    conference.dispose();
  });
}
