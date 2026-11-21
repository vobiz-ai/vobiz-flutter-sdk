// Access token sign-in in the example: a token from the token server, the
// SDK signs in with it as <sub>_<iss>, and nothing secret is stored.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

import 'support/fakes.dart';

/// A token shaped like the ones `POST /Account/{auth_id}/JWT/Token/` mints.
String jwt({String sub = 'agent42', String iss = 'MA_TESTACCT'}) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part(<String, String>{'alg': 'HS256', 'typ': 'JWT'})}.${part(<String, Object>{
        'iss': iss,
        'sub': sub,
        'nbf': now,
        'exp': now + 3600,
        'per': <String, Object>{
          'voice': <String, bool>{'incoming_allow': true, 'outgoing_allow': true},
        },
      })}.c2ln';
}

void main() {
  late FakeClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    client = FakeClient();
  });

  PlaygroundController make(http.Client http) => PlaygroundController(
        client: client,
        callScreen: FakeCallScreen(),
        platform: FakeCallPlatform(),
        httpClient: http,
      );

  test('signs in with a token from the token server, as <sub>_<iss>', () async {
    final token = jwt();
    final requests = <http.Request>[];
    final controller = make(MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(<String, String>{'token': token}), 200);
    }));
    await controller.init();
    controller.setAuthTab(AuthTab.accessToken);
    controller.tokenServerUrl = 'https://tokens.example.test/token';

    await controller.connect();

    expect(requests.single.url.toString(), 'https://tokens.example.test/token');
    expect(jsonDecode(requests.single.body), <String, String>{'reason': 'sign_in'});
    expect(client.actions, contains('connectWithAccessToken'));
    expect(client.tokens, <String>[token]);
    expect(controller.connectedAs, 'agent42_MA_TESTACCT');
    expect(controller.connectError, isNull);
    expect(controller.logs.map((l) => l.message),
        contains(startsWith('Access token for agent42_MA_TESTACCT: valid until')));

    await controller.disconnect();
    expect(client.actions.last, 'disconnect');
    controller.dispose();
  });

  test('with no token server, the sample server\'s /token is asked with its key and the user id', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{'vobiz_push_server': 'https://bridge.example#key=k1'});
    final token = jwt();
    final requests = <http.Request>[];
    final controller = make(MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(<String, String>{'token': token}), 200);
    }));
    await controller.init();
    controller.setAuthTab(AuthTab.accessToken);
    controller.tokenUser = 'agent42';

    await controller.connect();

    final asked = requests.single;
    expect(asked.url.toString(), 'https://bridge.example/token');
    expect(asked.headers['X-Bridge-Key'], 'k1');
    expect(asked.headers.containsKey('Authorization'), isFalse);
    expect(jsonDecode(asked.body), <String, String>{'reason': 'sign_in', 'sub': 'agent42'});
    expect(client.tokens, <String>[token]);
    expect(controller.connectedAs, 'agent42_MA_TESTACCT');
    controller.dispose();
  });

  test('without a token server or a sample server it says so, and signs nothing in', () async {
    final controller = make(MockClient((_) async => http.Response('{}', 500)));
    await controller.init();
    controller.setAuthTab(AuthTab.accessToken);

    await controller.connect();

    expect(controller.missingFields, contains('tokenServer'));
    expect(controller.connectError, contains('token server'));
    expect(client.actions, isNot(contains('connectWithAccessToken')));
    controller.dispose();
  });

  test('a token server that refuses shows an access token error', () async {
    final controller = make(MockClient((_) async => http.Response('nope', 401)));
    await controller.init();
    controller.setAuthTab(AuthTab.accessToken);
    controller.tokenServerUrl = 'https://tokens.example.test/token';

    await controller.connect();

    expect(controller.connectError, startsWith('Access token error:'));
    expect(controller.connectError, contains('HTTP 401'));
    expect(controller.connectedAs, isNull);
    expect(client.actions, isNot(contains('connectWithAccessToken')));
    controller.dispose();
  });

  test('the tab and the token server are remembered; no token is stored', () async {
    final token = jwt();
    final first = make(MockClient((_) async =>
        http.Response(jsonEncode(<String, String>{'token': token}), 200)));
    await first.init();
    first.setAuthTab(AuthTab.accessToken);
    first.tokenServerUrl = 'https://tokens.example.test/token';
    first.tokenUser = 'agent42';
    await first.connect();
    first.dispose();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vobiz_playground_mode'), 'token');
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.values.any((v) => v.contains(token)), isFalse);

    final second = make(MockClient((_) async => http.Response('{}', 500)));
    await second.init();
    expect(second.authTab, AuthTab.accessToken);
    expect(second.tokenServerUrl, 'https://tokens.example.test/token');
    expect(second.tokenUser, 'agent42');
    second.dispose();
  });
}
