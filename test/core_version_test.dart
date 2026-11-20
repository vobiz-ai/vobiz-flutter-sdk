// The version the SDK reports to Vobiz's push service (sdk_version) is the
// one it is published as.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  test('VobizClient.sdkVersion is the version in pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(VobizClient.sdkVersion, line.substring('version:'.length).trim());
  });
}
