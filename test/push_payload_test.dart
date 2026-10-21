import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  group('VobizIncomingPush', () {
    test('reads an incoming_call push', () {
      final push = VobizIncomingPush.tryParse(<String, Object?>{
        'type': 'incoming_call',
        'call_id': 'c-1',
        'call_key': 'k',
        'caller': '+919876543210',
        'callee': '+918000000000',
        'expires_at': '1760000060000',
      })!;
      expect(push.kind, VobizPushKind.incomingCall);
      expect(push.callId, 'c-1');
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1760000000000)), isFalse);
      expect(push.isExpired(DateTime.fromMillisecondsSinceEpoch(1760000060000)), isTrue);
    });

    test('ignores other data messages', () {
      expect(VobizIncomingPush.tryParse(<String, Object?>{'type': 'check'}), isNull);
      expect(VobizIncomingPush.tryParse(<String, Object?>{'type': 'incoming_call'}), isNull);
    });

    test('matches the INVITE by PushRef, else by caller number', () {
      final push = VobizIncomingPush.tryParse(<String, Object?>{
        'type': 'incoming_call',
        'call_id': 'c-1',
        'caller': '+919876543210',
      })!;
      expect(push.matchesIncomingCall(headers: <String, String>{'X-VH-PushRef': 'c-1'}), isTrue);
      expect(push.matchesIncomingCall(headers: <String, String>{'X-VH-PushRef': 'c-2'}, from: '+919876543210'),
          isFalse);
      expect(push.matchesIncomingCall(headers: const <String, String>{}, from: '09876543210'), isTrue);
      expect(push.matchesIncomingCall(headers: <String, String>{'X-VH-Caller': '919876543210'}), isTrue);
      expect(push.matchesIncomingCall(headers: const <String, String>{}, from: '+911111111111'), isFalse);
    });
  });
}
