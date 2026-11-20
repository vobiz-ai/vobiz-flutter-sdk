import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';
import 'package:vobiz_webrtc_example/src/app.dart';
import 'package:vobiz_webrtc_example/src/playground_controller.dart';
import 'package:vobiz_webrtc_example/src/screens/dialer_panel.dart';
import 'package:vobiz_webrtc_example/src/screens/trace_panel.dart';
import 'package:vobiz_webrtc_example/src/widgets/keypad.dart';

import 'support/fakes.dart';

/// The screens themselves: sheets, fields, the pill, the trace, and what a
/// screen reader hears.
void main() {
  late FakeClient client;
  late PlaygroundController controller;

  Future<void> openApp(WidgetTester tester, {Map<String, String> secure = const <String, String>{}}) async {
    tester.view.physicalSize = const Size(1236, 2745);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'vobiz_sip_username': 'play1',
      'vobiz_sip_password': 'pw',
      ...secure,
    });
    client = FakeClient();
    controller = PlaygroundController(client: client, callScreen: FakeCallScreen(), platform: FakeCallPlatform());
    await tester.pumpWidget(PlaygroundApp(controller: controller));
    await tester.pumpAndSettle();
  }

  /// Signed in with SIP Direct; the shell then shows the Dialer.
  Future<void> signIn(WidgetTester tester) async {
    controller.setAuthTab(AuthTab.sipDirect);
    await controller.connect();
    await tester.pumpAndSettle();
  }

  Future<void> answerCall(WidgetTester tester) async {
    client.direction = CallDirection.outbound;
    client.emit(CallStateStatus.active, dir: CallDirection.outbound);
    await tester.pumpAndSettle();
  }

  Future<void> endCall(WidgetTester tester) async {
    client.emit(CallStateStatus.ended, dir: CallDirection.outbound);
    await tester.pumpAndSettle();
  }

  Finder inDialer(Finder finder) => find.descendant(of: find.byType(DialerPanel), matching: finder);

  String fieldText(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).controller.text;

  group('the call sheets', () {
    for (final (name, icon) in <(String, IconData)>[('Transfer', Icons.phone_forwarded), ('Conference', Icons.group_add)]) {
      testWidgets('the $name sheet stays above the keyboard', (tester) async {
        await openApp(tester);
        await signIn(tester);
        await answerCall(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 900);
        addTearDown(tester.view.resetViewInsets);
        await tester.tap(inDialer(find.byIcon(icon)));
        await tester.pumpAndSettle();
        expect(find.byWidgetPredicate((w) => w is Padding && w.padding == const EdgeInsets.only(bottom: 300)),
            findsOneWidget, reason: 'the 300 px keyboard is kept clear');
        await endCall(tester);
      });
    }

    testWidgets('the Transfer sheet closes when the call ends', (tester) async {
      await openApp(tester);
      await signIn(tester);
      await answerCall(tester);
      await tester.tap(inDialer(find.byIcon(Icons.phone_forwarded)));
      await tester.pumpAndSettle();
      expect(find.text('WHAT MOVES'), findsOneWidget);
      await endCall(tester);
      expect(find.text('WHAT MOVES'), findsNothing);
    });

    testWidgets('the SIP user typed in the Transfer sheet is still there after switching to Number and back',
        (tester) async {
      await openApp(tester);
      await signIn(tester);
      await answerCall(tester);
      await tester.tap(inDialer(find.byIcon(Icons.phone_forwarded)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SIP user'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('transferUser')), 'alice');
      await tester.tap(find.text('Number'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SIP user'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, find.byKey(const Key('transferUser'))), 'alice');
      expect(controller.transferUser, 'alice');
      await endCall(tester);
    });
  });

  group('number fields', () {
    testWidgets('a typed "+" stays, and a calling code moves into the country picker', (tester) async {
      await openApp(tester);
      await signIn(tester);
      final field = find.descendant(of: find.byKey(const Key('destination')), matching: find.byType(TextField));
      await tester.enterText(field, '+');
      await tester.pump();
      expect(fieldText(tester, field), '+');
      await tester.enterText(field, '+4');
      await tester.pump();
      expect(fieldText(tester, field), '+4');
      await tester.enterText(field, '+44');
      await tester.pump();
      expect(controller.destIso, 'GB');
      await tester.enterText(field, '+447911');
      await tester.pump();
      expect(controller.destNumber, '7911');
      expect(fieldText(tester, field), '7911', reason: 'the code went into the picker');
      await tester.enterText(field, '7911 123');
      await tester.pump();
      expect(controller.destNumber, '7911123');
      expect(fieldText(tester, field), '7911 123', reason: 'the space typed stays');
    });

    testWidgets('the keypad still writes into the field', (tester) async {
      await openApp(tester);
      await signIn(tester);
      await tester.tap(find.descendant(of: find.byType(Keypad), matching: find.text('5')));
      await tester.pump();
      final field = find.descendant(of: find.byKey(const Key('destination')), matching: find.byType(TextField));
      expect(fieldText(tester, field), '5');
    });
  });

  testWidgets('a long status does not overflow the Dialer header', (tester) async {
    await openApp(tester);
    await signIn(tester);
    controller.update(() => controller.statusText = 'Offline: waiting for a call through Vobiz push');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('DIALER TERMINAL'), findsOneWidget);
  });

  testWidgets('"Got it" closes an info tip whose field an incoming call replaced', (tester) async {
    await openApp(tester);
    await signIn(tester);
    await tester.tap(inDialer(find.byIcon(Icons.info_outline)).first);
    await tester.pumpAndSettle();
    expect(find.text('PSTN Requirement'), findsOneWidget);
    client.ring();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('PSTN Requirement'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sample server line saved earlier fills its field once start-up has read it', (tester) async {
    await openApp(tester, secure: <String, String>{'vobiz_push_server': 'https://bridge.example#key=k1'});
    final field = find.byKey(const Key('pushServer'));
    expect(tester.widget<TextField>(field).controller!.text, 'https://bridge.example#key=k1');
    expect(find.text('Sample server'), findsOneWidget);
  });

  testWidgets('the webhook dialog saves what was typed and closes cleanly', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('PRODUCTION WEBHOOK CALLBACK'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('webhookField')), 'https://my-server.example');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(controller.webhookUrl, 'https://my-server.example');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the trace follows new lines again after Clear', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('Trace'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 80; i++) {
      controller.log('line $i', LogType.info);
    }
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(TracePanel), matching: find.byType(ListView));
    await tester.drag(list, const Offset(0, 400));
    await tester.pumpAndSettle();
    controller.clearLogs();
    await tester.pumpAndSettle();
    for (var i = 0; i < 80; i++) {
      controller.log('again $i', LogType.info);
    }
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(
        find.descendant(of: find.byType(TracePanel), matching: find.byType(Scrollable)).first).position;
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('a screen reader names the number fields, the in-call buttons and the info tips', (tester) async {
    final semantics = tester.ensureSemantics();
    await openApp(tester);
    await signIn(tester);
    expect(find.bySemanticsLabel(RegExp('^Destination number(?! country)')), findsOneWidget);
    expect(find.bySemanticsLabel('About PSTN Requirement'), findsOneWidget);
    await answerCall(tester);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Mute')),
      isSemantics(label: 'Mute', isButton: true, hasToggledState: true, isToggled: false, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Transfer')),
      isSemantics(label: 'Transfer', isButton: true, hasToggledState: false, hasTapAction: true),
    );
    await endCall(tester);
    semantics.dispose();
  });
}
