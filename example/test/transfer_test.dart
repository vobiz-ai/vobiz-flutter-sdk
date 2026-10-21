import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';

/// #48: which leg "Move me" sends depends on who placed the call.
void main() {
  test('the Redirect API offers aleg, bleg and both', () {
    expect(TransferLeg.values.map((l) => l.apiValue), <String>['aleg', 'bleg', 'both']);
  });

  test('a call this app placed: the app is the A-leg', () {
    expect(transferLegFor(TransferParty.me, CallDirection.outbound), TransferLeg.aLeg);
    expect(transferLegFor(TransferParty.other, CallDirection.outbound), TransferLeg.bLeg);
    expect(transferLegFor(TransferParty.both, CallDirection.outbound), TransferLeg.both);
  });

  test('a call that rang this app: the caller is the A-leg, the app the B-leg', () {
    expect(transferLegFor(TransferParty.me, CallDirection.inbound), TransferLeg.bLeg);
    expect(transferLegFor(TransferParty.other, CallDirection.inbound), TransferLeg.aLeg);
    expect(transferLegFor(TransferParty.both, CallDirection.inbound), TransferLeg.both);
  });
}
