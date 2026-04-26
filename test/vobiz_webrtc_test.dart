// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc/src/signaling/sip_service.dart';

void main() {
  // ── SipParser ──────────────────────────────────────────────────────────────

  group('SipParser', () {
    test('parses a SIP REGISTER request', () {
      const raw = 'REGISTER sip:registrar.vobiz.ai SIP/2.0\r\n'
          'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKabc\r\n'
          'From: <sip:alice@registrar.vobiz.ai>;tag=1234\r\n'
          'To: <sip:alice@registrar.vobiz.ai>\r\n'
          'Call-ID: callid123\r\n'
          'CSeq: 1 REGISTER\r\n'
          'Content-Length: 0\r\n'
          '\r\n';

      final msg = SipParser.parse(raw);

      expect(msg.isRequest, isTrue);
      expect(msg.method, equals('REGISTER'));
      expect(msg.header('From'), contains('alice'));
      expect(msg.header('Call-ID'), equals('callid123'));
      expect(msg.header('CSeq'), equals('1 REGISTER'));
      expect(msg.body, isEmpty);
    });

    test('parses a SIP 200 OK response', () {
      const raw = 'SIP/2.0 200 OK\r\n'
          'Via: SIP/2.0/WSS vobiz-client;branch=z9hG4bKabc\r\n'
          'From: <sip:alice@registrar.vobiz.ai>;tag=1234\r\n'
          'To: <sip:alice@registrar.vobiz.ai>;tag=5678\r\n'
          'Call-ID: callid123\r\n'
          'CSeq: 1 REGISTER\r\n'
          'Content-Length: 0\r\n'
          '\r\n';

      final msg = SipParser.parse(raw);

      expect(msg.isRequest, isFalse);
      expect(msg.statusCode, equals(200));
      expect(msg.header('To'), contains('5678'));
    });

    test('parses a SIP 401 Unauthorized with WWW-Authenticate header', () {
      const raw = 'SIP/2.0 401 Unauthorized\r\n'
          'WWW-Authenticate: Digest realm="registrar.vobiz.ai",'
          ' nonce="abc123", algorithm=MD5\r\n'
          'Content-Length: 0\r\n'
          '\r\n';

      final msg = SipParser.parse(raw);

      expect(msg.statusCode, equals(401));
      expect(msg.header('WWW-Authenticate'), contains('nonce'));
    });

    test('parses a SIP INVITE with SDP body', () {
      const sdp = 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n';
      final raw = 'INVITE sip:bob@registrar.vobiz.ai SIP/2.0\r\n'
          'Content-Type: application/sdp\r\n'
          'Content-Length: ${sdp.length}\r\n'
          '\r\n'
          '$sdp';

      final msg = SipParser.parse(raw);

      expect(msg.isRequest, isTrue);
      expect(msg.method, equals('INVITE'));
      expect(msg.body, isNotEmpty);
    });

    test('handles malformed message without crashing', () {
      const raw = 'NOT A VALID SIP MESSAGE';
      expect(() => SipParser.parse(raw), returnsNormally);
    });

    test('handles empty string without crashing', () {
      expect(() => SipParser.parse(''), returnsNormally);
    });

    test('header lookup is case-insensitive', () {
      const raw = 'SIP/2.0 200 OK\r\n'
          'call-id: lowercase-header\r\n'
          'Content-Length: 0\r\n'
          '\r\n';

      final msg = SipParser.parse(raw);
      expect(msg.header('Call-ID'), equals('lowercase-header'));
      expect(msg.header('call-id'), equals('lowercase-header'));
      expect(msg.header('CALL-ID'), equals('lowercase-header'));
    });
  });

  // ── SdkConfig ──────────────────────────────────────────────────────────────

  group('SdkConfig', () {
    test('has correct default values', () {
      const config = SdkConfig();

      expect(config.wsUrl, equals('wss://registrar.vobiz.ai:5063/'));
      expect(config.sipServer, equals('registrar.vobiz.ai'));
      expect(config.backendUrl, equals('http://10.0.2.2:3000'));
      expect(config.autoReconnect, isTrue);
      expect(config.debug, isFalse);
    });

    test('accepts custom values', () {
      const config = SdkConfig(
        wsUrl: 'wss://custom.example.com:5063/',
        sipServer: 'custom.example.com',
        backendUrl: 'https://api.example.com',
        autoReconnect: false,
        debug: true,
      );

      expect(config.wsUrl, equals('wss://custom.example.com:5063/'));
      expect(config.sipServer, equals('custom.example.com'));
      expect(config.backendUrl, equals('https://api.example.com'));
      expect(config.autoReconnect, isFalse);
      expect(config.debug, isTrue);
    });
  });

  // ── IceConfig ──────────────────────────────────────────────────────────────

  group('IceConfig', () {
    test('defaults to Google STUN', () {
      const ice = IceConfig();
      expect(ice.servers, hasLength(1));
      expect(ice.servers.first.urls.first, contains('stun.l.google.com'));
    });

    test('toRtcConfiguration returns correct structure', () {
      const ice = IceConfig();
      final rtc = ice.toRtcConfiguration();
      expect(rtc['iceServers'], isList);
    });

    test('accepts custom TURN servers', () {
      const ice = IceConfig(
        servers: [
          IceServerConfig(
            urls: ['turn:turn.example.com:3478'],
            username: 'user',
            credential: 'pass',
          ),
        ],
      );
      expect(ice.servers.first.username, equals('user'));
      expect(ice.servers.first.credential, equals('pass'));
    });
  });

  // ── MediaConstraints ───────────────────────────────────────────────────────

  group('MediaConstraints', () {
    test('defaults to audio-only with processing enabled', () {
      const mc = MediaConstraints();
      expect(mc.audio, isTrue);
      expect(mc.video, isFalse);
      expect(mc.echoCancellation, isTrue);
      expect(mc.noiseSuppression, isTrue);
      expect(mc.autoGainControl, isTrue);
    });

    test('toWebRtcConstraints includes audio processing flags', () {
      const mc = MediaConstraints();
      final constraints = mc.toWebRtcConstraints();
      expect(constraints['video'], isFalse);
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio['echoCancellation'], isTrue);
    });

    test('toWebRtcConstraints with audio=false returns false for audio', () {
      const mc = MediaConstraints(audio: false);
      final constraints = mc.toWebRtcConstraints();
      expect(constraints['audio'], isFalse);
    });
  });

  // ── CredentialConfig ───────────────────────────────────────────────────────

  group('CredentialConfig', () {
    test('stores username and password', () {
      const cred = CredentialConfig(
        username: 'alice',
        password: 's3cr3t',
      );
      expect(cred.username, equals('alice'));
      expect(cred.password, equals('s3cr3t'));
      expect(cred.displayName, isNull);
    });
  });

  // ── CallStateStatus ────────────────────────────────────────────────────────

  group('CallStateStatus', () {
    test('contains all expected states', () {
      const states = CallStateStatus.values;
      expect(states, contains(CallStateStatus.idle));
      expect(states, contains(CallStateStatus.incoming));
      expect(states, contains(CallStateStatus.ringing));
      expect(states, contains(CallStateStatus.connecting));
      expect(states, contains(CallStateStatus.active));
      expect(states, contains(CallStateStatus.held));
      expect(states, contains(CallStateStatus.ended));
      expect(states, contains(CallStateStatus.failed));
    });
  });

  // ── DtmfTone ───────────────────────────────────────────────────────────────

  group('DtmfTone', () {
    test('digit values are correct', () {
      expect(DtmfTone.digit0.value, equals('0'));
      expect(DtmfTone.digit9.value, equals('9'));
      expect(DtmfTone.star.value, equals('*'));
      expect(DtmfTone.hash.value, equals('#'));
    });
  });
}
