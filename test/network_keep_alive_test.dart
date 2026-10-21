// Issue #35 (keep-alive part) and #18 (dead-socket detection).
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/src/network/keep_alive.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

import 'network_fakes.dart';

const String _register200 = 'SIP/2.0 200 OK\r\n'
    'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKx\r\n'
    'From: <sip:play1@registrar.vobiz.ai>;tag=t\r\n'
    'To: <sip:play1@registrar.vobiz.ai>;tag=srv\r\n'
    'Call-ID: reg@vobiz-client\r\n'
    'CSeq: 1 REGISTER\r\n'
    'Content-Length: 0\r\n\r\n';

/// A WebSocket server that completes the handshake and then never answers
/// anything again, pings included: a connection whose network has silently
/// gone away.
Future<ServerSocket> _blackHoleServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((Socket s) {
    var buf = '';
    var upgraded = false;
    s.listen((List<int> data) {
      if (upgraded) return; // swallow everything, pings included
      buf += latin1.decode(data);
      if (!buf.contains('\r\n\r\n')) return;
      final key = RegExp(r'Sec-WebSocket-Key: (.+)\r\n', caseSensitive: false)
          .firstMatch(buf)!
          .group(1)!
          .trim();
      final accept = base64.encode(
          sha1.convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
      s.write('HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n'
          'Sec-WebSocket-Protocol: sip\r\n\r\n');
      upgraded = true;
    }, onError: (_) {});
  });
  return server;
}

void main() {
  group('keep-alive (#35)', () {
    test('no OPTIONS to sip:admin@<registrar> after registering', () {
      fakeAsync((FakeAsync async) {
        final sent = <String>[];
        final s = SIPService(wsUrl: 'wss://t', sipServer: 'registrar.vobiz.ai')
          ..debugOnSend = sent.add;
        s.connectionState.value = SipConnectionState.connected;
        s.register('play1', 'secret');
        s.debugReceive(_register200);
        sent.clear();

        async.elapse(const Duration(minutes: 5));
        expect(sent.where((String m) => m.startsWith('OPTIONS')), isEmpty,
            reason: 'the registrar answers these "No contact found" and logs an '
                'ERROR each time; sent: ${sent.map((m) => m.split('\r\n').first)}');
        s.disconnect();
      });
    });

    test('the default keep-alive is a WebSocket ping faster than the old 30 s', () {
      const k = KeepAliveConfig();
      expect(k.pingInterval, isNotNull);
      expect(k.pingInterval!, lessThan(const Duration(seconds: 30)));
      expect(k.crlfInterval, isNull, reason: 'CRLF only for registrars that answer it');
    });

    test('CRLF keep-alive, when enabled, sends a double CRLF and accepts a CRLF pong', () {
      fakeAsync((FakeAsync async) {
        final sent = <String>[];
        final s = SIPService(
          wsUrl: 'wss://t',
          sipServer: 'registrar.vobiz.ai',
          keepAlive: const KeepAliveConfig(crlfInterval: Duration(seconds: 25)),
        )..debugOnSend = sent.add;
        s.connectionState.value = SipConnectionState.connected;
        s.register('play1', 'secret');
        s.debugReceive(_register200);
        sent.clear();

        async.elapse(const Duration(seconds: 25));
        expect(sent, <String>['\r\n\r\n']);
        s.debugReceive('\r\n'); // pong
        async.elapse(const Duration(seconds: 25));
        expect(sent, <String>['\r\n\r\n', '\r\n\r\n']);
        s.disconnect();
      });
    });

    test('CrlfKeepAlive reports a dead flow when no pong arrives', () {
      fakeAsync((FakeAsync async) {
        var dead = 0;
        final pings = <String>[];
        final k = CrlfKeepAlive(
          interval: const Duration(seconds: 25),
          pongTimeout: const Duration(seconds: 10),
          send: pings.add,
          onDead: () => dead++,
        )..start();
        async.elapse(const Duration(seconds: 25));
        expect(pings, hasLength(1));
        async.elapse(const Duration(seconds: 9));
        expect(dead, 0);
        async.elapse(const Duration(seconds: 1));
        expect(dead, 1);
        expect(k.isRunning, isFalse);
      });
    });
  });

  group('dead-socket detection (#18)', () {
    test('a silently dead WebSocket is reported within two ping intervals', () async {
      final server = await _blackHoleServer();
      final s = SIPService(
        wsUrl: 'ws://127.0.0.1:${server.port}/',
        sipServer: 'registrar.vobiz.ai',
        keepAlive: const KeepAliveConfig(pingInterval: Duration(milliseconds: 200)),
      );
      final lost = Completer<String>();
      s.onSocketError = (String r) {
        if (!lost.isCompleted) lost.complete(r);
      };
      final sw = Stopwatch()..start();
      await s.connect();
      expect(s.connectionState.value, SipConnectionState.connected);
      final reason = await lost.future.timeout(const Duration(seconds: 3));
      expect(reason, contains('socket'));
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(s.connectionState.value, SipConnectionState.disconnected);
      s.disconnect();
      await server.close();
    });

    test('CRLF keep-alive without a pong closes the socket and reports the drop', () async {
      final server = FakeSipServer();
      await server.start();
      final s = SIPService(
        wsUrl: server.url,
        sipServer: 'registrar.vobiz.ai',
        keepAlive: const KeepAliveConfig(
          pingInterval: null,
          crlfInterval: Duration(milliseconds: 100),
          crlfPongTimeout: Duration(milliseconds: 100),
        ),
      );
      final lost = Completer<String>();
      s.onSocketError = (String r) {
        if (!lost.isCompleted) lost.complete(r);
      };
      await s.connect();
      s.register('play1', 'secret');
      await eventually(
          () => s.registrationState.value == SipRegistrationState.registered);
      // FakeSipServer never answers the CRLF ping.
      await lost.future.timeout(const Duration(seconds: 3));
      expect(server.received, contains('\r\n\r\n'));
      s.disconnect();
      await server.stop();
    });
  });
}
