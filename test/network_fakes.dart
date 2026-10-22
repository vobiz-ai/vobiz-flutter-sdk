// Test doubles for the network tests: a connectivity monitor the test drives,
// and an in-process SIP-over-WebSocket "registrar" that answers REGISTER and
// can drop connections or refuse them.
import 'dart:async';
import 'dart:io';

import 'package:vobiz_webrtc/vobiz_webrtc.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor([NetworkStatus? initial])
      : _now = initial ?? NetworkStatus(const <NetworkType>[NetworkType.wifi]);

  NetworkStatus _now;
  final StreamController<NetworkStatus> _changes =
      StreamController<NetworkStatus>.broadcast(sync: true);

  @override
  Future<NetworkStatus> current() async => _now;

  @override
  Stream<NetworkStatus> get changes => _changes.stream;

  void emit(NetworkStatus status) {
    _now = status;
    _changes.add(status);
  }

  void goOffline() => emit(NetworkStatus.offline());
  void wifi() => emit(NetworkStatus(const <NetworkType>[NetworkType.wifi]));
  void mobile() => emit(NetworkStatus(const <NetworkType>[NetworkType.mobile]));
}

class FakeSipServer {
  HttpServer? _http;
  final List<WebSocket> sockets = <WebSocket>[];
  final List<String> received = <String>[];
  bool answerRegister = true;

  /// Status the registrar answers REGISTER with (200, or a refusal).
  int registerStatus = 200;

  /// Lifetime granted in the 200 OK's Contact.
  int grantSeconds = 3600;

  /// Connections that read but never answer: a socket that died silently.
  final Set<WebSocket> muted = <WebSocket>{};

  /// Silences every open connection; new ones are answered as usual.
  void muteAll() => muted.addAll(sockets);
  bool acceptConnections = true;
  int connections = 0;

  int get port => _http!.port;
  String get url => 'ws://127.0.0.1:$port/';

  List<String> get registers =>
      received.where((String m) => m.startsWith('REGISTER ')).toList();

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http!.listen((HttpRequest req) async {
      if (!acceptConnections) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req,
          protocolSelector: (List<String> p) => 'sip');
      connections++;
      sockets.add(ws);
      ws.listen((dynamic data) {
        final msg = data.toString();
        received.add(msg);
        if (msg.startsWith('REGISTER ') && answerRegister && !muted.contains(ws)) {
          ws.add(_ok(msg, status: registerStatus, grant: grantSeconds));
        }
      }, onError: (_) {});
    });
  }

  /// Closes every open connection from the server side.
  Future<void> dropAll() async {
    final open = List<WebSocket>.of(sockets);
    sockets.clear();
    for (final ws in open) {
      await ws.close();
    }
  }

  Future<void> stop() async {
    await dropAll();
    await _http?.close(force: true);
  }

  static String _ok(String request, {int status = 200, int grant = 3600}) {
    String h(String name) => request
        .split(RegExp(r'\r?\n'))
        .firstWhere((String l) => l.toLowerCase().startsWith('${name.toLowerCase()}:'),
            orElse: () => '$name: ')
        .substring(name.length + 1)
        .trim();
    return 'SIP/2.0 $status ${status == 200 ? 'OK' : 'Refused'}\r\n'
        'Via: ${h('Via')}\r\n'
        'From: ${h('From')}\r\n'
        'To: ${h('To')};tag=srv\r\n'
        'Call-ID: ${h('Call-ID')}\r\n'
        'CSeq: ${h('CSeq')}\r\n'
        'Contact: ${h('Contact')};expires=$grant\r\n'
        'Content-Length: 0\r\n\r\n';
  }
}

/// Polls [condition] until it holds or [timeout] passes.
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
