// Shared fixtures for the SIP tests: a service wired to a list of sent
// messages, responses that echo a request the way a server does, and a fake
// WebSocket for the tests that need a socket to close.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:vobiz_webrtc/src/signaling/sip_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A service signed in as `play1`, its REGISTER already sent and cleared.
SIPService sipService(List<String> sent, {bool registered = false}) {
  final s = SIPService(wsUrl: 'wss://test', sipServer: 'registrar.vobiz.ai')
    ..debugOnSend = sent.add;
  s.register('play1', 'secret');
  if (registered) s.debugReceive(respond(sent.last, 200, 'OK'));
  sent.clear();
  return s;
}

/// A response to [request] as Vobiz sends it: every Via, From, Call-ID and
/// CSeq copied, and a To tag added.
String respond(
  String request,
  int code,
  String reason, {
  String toTag = 'far',
  List<String> headers = const <String>[],
  String body = '',
}) {
  final m = SipParser.parse(request);
  final to = m.header('To') ?? '';
  return <String>[
    'SIP/2.0 $code $reason',
    for (final via in m.headerValues('Via')) 'Via: $via',
    'From: ${m.header('From')}',
    'To: ${to.contains('tag=') || toTag.isEmpty ? to : '$to;tag=$toTag'}',
    'Call-ID: ${m.header('Call-ID')}',
    'CSeq: ${m.header('CSeq')}',
    ...headers,
    if (body.isNotEmpty) 'Content-Type: application/sdp',
    'Content-Length: ${body.length}',
    '',
    body,
  ].join('\r\n');
}

/// The value of the first [header] in [message], or '' when absent.
String headerOf(String message, String header) => message
    .split('\r\n')
    .firstWhere((l) => l.toLowerCase().startsWith('${header.toLowerCase()}:'), orElse: () => '')
    .split(':')
    .skip(1)
    .join(':')
    .trim();

/// The request line or status line of [message].
String firstLine(String message) => message.split('\r\n').first;

/// The method (or `SIP/2.0`) of each message.
List<String> methods(List<String> messages) =>
    messages.map((m) => m.split(' ').first).toList();

String branchOf(String message) =>
    RegExp(r'branch=([^;\s]+)').firstMatch(headerOf(message, 'Via'))!.group(1)!;

/// An inbound INVITE as Vobiz's registrar delivers it.
String inboundInvite({String callId = 'in-call-1', String branch = 'z9hG4bKkam.1', int cseq = 101, String sdp = 'v=0\r\no=- 1 1 IN IP4 10.0.2.9'}) =>
    'INVITE sip:abcd1234@203.0.113.5:40000;transport=ws SIP/2.0\r\n'
    'Record-Route: <sip:10.0.1.5:443;transport=ws;r2=on;lr>\r\n'
    'Via: SIP/2.0/WSS 10.0.1.5:443;branch=$branch\r\n'
    'From: "+918000000000" <sip:+918000000000@10.0.2.9>;tag=ms-tag\r\n'
    'To: <sip:play1@registrar.vobiz.ai>\r\n'
    'Call-ID: $callId\r\n'
    'CSeq: $cseq INVITE\r\n'
    'Contact: <sip:Vobiz@10.0.2.9:5060>\r\n'
    'Content-Type: application/sdp\r\n'
    'Content-Length: ${sdp.length}\r\n'
    '\r\n'
    '$sdp';

/// A WebSocket that records what is sent and whether it was closed.
class FakeSocket implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final FakeSink fakeSink = FakeSink();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => fakeSink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSink implements WebSocketSink {
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  void add(dynamic data) {
    if (closed) throw StateError('closed');
    sent.add(data.toString());
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
