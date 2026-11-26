import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// Named Playground users: phones on one account, each under its own name,
/// calling each other.
void main() {
  late FakeClient client;
  late List<http.Request> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    client = FakeClient();
    requests = <http.Request>[];
  });

  PlaygroundController make({http.Client? web}) => PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: FakeCallPlatform(),
        httpClient: web,
      );

  test('Zero-Config signs in under the name, lower-cased, and remembers it', () async {
    final c = make();
    await c.init();
    c
      ..authId = 'MA_X'
      ..authToken = 'tok'
      ..zeroConfigName = ' Alice ';
    await c.connect();
    expect(client.zeroConfigUserName, 'alice');

    final again = make();
    await again.init();
    expect(again.zeroConfigName.trim(), 'Alice');
  });

  test('without a name, the shared Playground endpoint as before', () async {
    final c = make();
    await c.init();
    c
      ..authId = 'MA_X'
      ..authToken = 'tok';
    await c.connect();
    expect(client.zeroConfigUserName, isNull);
  });

  test('lists the account users from the webhook server', () async {
    final c = make(web: MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode(<String, Object>{
            'users': <Object>[
              <String, Object>{'name': 'alice', 'sip_username': 'alice0123', 'registered': true},
              <String, Object>{'name': 'bob', 'sip_username': 'bob0456', 'registered': false},
              <String, Object>{'name': 'broken'},
            ],
          }),
          200);
    }));
    await c.init();
    c
      ..authId = 'MA_X'
      ..authToken = 'tok'
      ..webhookUrl = 'https://hooks.example.test/';
    final users = await c.playgroundUsers();
    expect(users.map((u) => '${u.name}:${u.sipUsername}:${u.registered}'),
        <String>['alice:alice0123:true', 'bob:bob0456:false']);
    expect(requests.single.url.toString(), 'https://hooks.example.test/api/users');
    expect(jsonDecode(requests.single.body)['auth_id'], 'MA_X');
  });

  test('a server without named users says so, and lists none', () async {
    final c = make(web: MockClient((_) async => http.Response('Not found', 404)));
    await c.init();
    c
      ..authId = 'MA_X'
      ..authToken = 'tok';
    expect(await c.playgroundUsers(), isEmpty);
    expect(c.logs.last.message, contains('does not support named users yet'));
  });

  test('calling a user sets Dial-User; picking again replaces it', () {
    final c = make();
    c.callPlaygroundUser(const PlaygroundUser(name: 'bob', sipUsername: 'bob0456'));
    expect(c.dialUserTarget, 'bob0456');
    c.callPlaygroundUser(const PlaygroundUser(name: 'carol', sipUsername: 'carol0789'));
    expect(c.headerRows.where((r) => r.name == VobizSipHeaders.dialUser).single.value, 'carol0789');
  });

  group('endpoint-to-endpoint calls', () {
    Future<PlaygroundController> signedIn({http.Client? web}) async {
      final c = make(web: web);
      await c.init();
      c
        ..authId = 'MA_X'
        ..authToken = 'tok'
        ..zeroConfigName = 'alice';
      await c.connect();
      return c;
    }

    test('need no number, and send the account number as caller ID', () async {
      final c = await signedIn(web: MockClient((request) async {
        requests.add(request);
        return http.Response(
            jsonEncode(<String, Object>{
              'items': <Object>[
                <String, Object>{'e164': '+12402128725', 'is_trial_number': true}
              ],
              'total': 1,
            }),
            200);
      }));
      c.callPlaygroundUser(const PlaygroundUser(name: 'bob', sipUsername: 'bob0456'));
      await c.call();
      expect(client.actions, contains('makeCall'));
      expect(client.lastDial!.destination, PlaygroundController.endpointCallRoute);
      expect(client.lastDial!.callerId, '+12402128725');
      final lookup = requests.single;
      expect(lookup.url.toString(), 'https://api.vobiz.ai/api/v1/account/MA_X/numbers?status=active&per_page=1');
      expect(lookup.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('MA_X:tok'))}');

      // Looked up once per sign-in.
      c.callPlaygroundUser(const PlaygroundUser(name: 'bob', sipUsername: 'bob0456'));
      await c.call();
      expect(requests, hasLength(1));
      expect(client.lastDial!.headers[VobizSipHeaders.dialUser], 'bob0456');
      expect(c.remoteParty, 'bob');
    });

    test('send no caller ID when the account number cannot be looked up', () async {
      final c = await signedIn(web: MockClient((_) async => http.Response('{"error":"nope"}', 403)));
      c.callPlaygroundUser(const PlaygroundUser(name: 'bob', sipUsername: 'bob0456'));
      await c.call();
      expect(client.actions, contains('makeCall'));
      expect(client.lastDial!.callerId, isNull);
      expect(c.logs.map((l) => l.message), contains(contains('the answer URL must set one')));
    });

    test('keep a caller ID and a number when they are entered', () async {
      final c = await signedIn();
      c
        ..callerIdIso = 'IN'
        ..callerIdNumber = '7965861256'
        ..destIso = 'IN'
        ..destNumber = '9000000001';
      c.callPlaygroundUser(const PlaygroundUser(name: 'bob', sipUsername: 'bob0456'));
      await c.call();
      expect(client.lastDial!.destination, '+919000000001');
      expect(client.lastDial!.callerId, '+917965861256');
    });

    test('a phone number still needs a caller ID', () async {
      final c = await signedIn();
      c
        ..destIso = 'IN'
        ..destNumber = '9000000001';
      await c.call();
      expect(client.actions, isNot(contains('makeCall')));
      expect(c.logs.last.message, contains('Caller ID is required'));
    });
  });
}
