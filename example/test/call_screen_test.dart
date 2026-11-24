import 'package:flutter_callkit_incoming/entities/entities.dart' as ck;
import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc_example/src/push/call_screen.dart';

void main() {
  group('CallScreen.uuidFor', () {
    // Python's uuid.uuid5(uuid.NAMESPACE_URL, key), which the iOS side
    // (AppDelegate.screenId) must match: a pushed call's CallKit screen is
    // made there, and Dart ends and matches it by the same id.
    const vectors = <String, String>{
      'abc123@10.0.0.1': '4b5eb8e1-d155-50d8-856c-07d2841c3fc6',
      'sip-a84b4c76e66710': '0efac849-21ea-587d-b19e-d46bfc796383',
      '1f0e8a5c-2b1d-4c3e-9f7a-0123456789ab': '7fb8870c-cf56-59ec-bd00-798e0063fe16',
    };

    vectors.forEach((key, uuid) {
      test(key, () => expect(CallScreen.uuidFor(key), uuid));
    });
  });

  group('CallScreen keys', () {
    test('Android takes the key as the id', () {
      expect(CallScreen.idFor('sip-a84b4c76e66710'), 'sip-a84b4c76e66710');
    });

    test('a screen is known by the key in its extra', () {
      const params = ck.CallKitParams(
        id: '0efac849-21ea-587d-b19e-d46bfc796383',
        extra: <String, dynamic>{'key': 'sip-a84b4c76e66710'},
      );
      expect(CallScreen.keyOf(params), 'sip-a84b4c76e66710');
      // A timeout reports the id alone.
      expect(CallScreen.keyOfId('0EFAC849-21EA-587D-B19E-D46BFC796383'), 'sip-a84b4c76e66710');
    });

    test('a screen without a key is known by its id', () {
      expect(CallScreen.keyOf(const ck.CallKitParams(id: 'push-1')), 'push-1');
    });
  });
}
