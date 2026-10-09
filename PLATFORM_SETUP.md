# Platform Setup Checklist

Before running your Flutter app with Vobiz SDK, ensure all platform permissions and configurations are in place.

---

## Android Setup

### Step 1: Update Minimum SDK Version

In `android/app/build.gradle`:

```gradle
android {
  compileSdkVersion 34

  defaultConfig {
    applicationId "com.example.your_app"
    minSdkVersion 21          // ← Must be 21+
    targetSdkVersion 34
    versionCode 1
    versionName "1.0.0"
  }
}
```

### Step 2: Add Required Permissions

In `android/app/src/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  
  <!-- Required for audio capture -->
  <uses-permission android:name="android.permission.RECORD_AUDIO" />
  
  <!-- Required for network access -->
  <uses-permission android:name="android.permission.INTERNET" />
  
  <!-- Required for WebRTC (device state) -->
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
  
  <!-- Required for WebRTC (call handling) -->
  <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
  
  <!-- Optional: For better network detection -->
  <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />

  <application>
    <!-- Your app activities here -->
  </application>

</manifest>
```

### Step 3: Request Runtime Permissions

Vobiz SDK handles microphone permission, but you should request it early in your app:

```dart
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request microphone permission
  final status = await Permission.microphone.request();
  
  if (status.isGranted) {
    print('✅ Microphone permission granted');
  } else if (status.isDenied) {
    print('❌ Microphone permission denied');
  }
  
  runApp(MyApp());
}
```

### Step 4: Add WebRTC Dependencies

In `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  vobiz_webrtc: ^0.1.0
  flutter_webrtc: ^0.9.0
  permission_handler: ^11.0.0
  intl: ^0.19.0
```

Then run:
```bash
flutter pub get
```

### Step 5: Verify WebRTC Support (Optional)

Add this to `android/app/build.gradle` to enable hardware acceleration:

```gradle
android {
  lintOptions {
    disable 'MissingDimensionBaseModule'
  }
}
```

### Step 6: Test on Device

```bash
flutter devices
flutter run -d <device-id>
```

Look for logs:
```
✅ I/flutter: 🔵 [WebRTC] Initialized successfully
✅ I/flutter: 📡 [SIP] Connected to registrar.vobiz.ai
```

---

## iOS Setup

### Step 1: Update Minimum Deployment Target

In `ios/Podfile`:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '$(inherited)',
        'PERMISSION_MICROPHONE=1',
      ]
    end
  end
end
```

In `ios/Runner.xcodeproj/project.pbxproj` (or use Xcode):
- **Minimum Deployment Target**: iOS 13.0+ (required by flutter_webrtc)

### Step 2: Add Privacy Descriptions

In `ios/Runner/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Microphone usage description -->
  <key>NSMicrophoneUsageDescription</key>
  <string>This app needs access to your microphone to make and receive calls.</string>
  
  <!-- Network permission (implicit) -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>This app uses local network for VoIP calls.</string>
  
  <!-- mDNS discovery (for WebRTC) -->
  <key>NSBonjourServices</key>
  <array>
    <string>_services._dns-sd._udp</string>
  </array>

  <!-- Your other keys here -->
</dict>
</plist>
```

### Step 3: Enable VoIP Capabilities (Optional)

In `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>voip</string>
</array>
```

This allows the app to receive calls even when closed (requires push notifications).

### Step 4: Update Xcode Build Settings

In Xcode:
1. Open `ios/Runner.xcworkspace` (NOT `.xcodeproj`)
2. Select **Runner** → **Build Settings**
3. Search for **`IPHONEOS_DEPLOYMENT_TARGET`**
4. Set to **13.0** or higher

### Step 5: Install Dependencies

```bash
cd ios
pod install
cd ..
```

### Step 6: Build and Test

```bash
flutter run -d <ios-device-id>
```

Look for logs:
```
✅ [WebRTC] Initialized successfully
✅ [SIP] Connected to registrar.vobiz.ai
```

---

## Web Setup (Testing Only)

⚠️ **Not recommended for production**

If testing on web:

```bash
flutter run -d chrome
```

**Limitations:**
- No PSTN calling (web cannot receive calls from PSTN)
- Requires HTTPS (WebRTC requires secure connection)
- Browser must support WebRTC

---

## Debugging Tips

### Enable Verbose Logging

```dart
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-backend.com',
    debug: true,  // ← Enable debug logs
  ),
);
```

### Check Permissions at Runtime

```dart
import 'package:permission_handler/permission_handler.dart';

final micStatus = await Permission.microphone.status;
print('Microphone: $micStatus');

final netStatus = await Permission.phone.status;
print('Network: $netStatus');
```

### Verify WebRTC on Android

1. Open Chrome DevTools: `chrome://webrtc-internals/`
2. On your Android device, navigate to: `about://webrtc-internals/`
3. Check if **WebRTC** section shows active connections

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Record Audio permission denied" | Grant permission in Android Settings > Apps > Your App > Permissions |
| "Cannot connect to SIP server" | Check INTERNET permission, verify firewall allows port 5063 |
| "WebRTC connection fails on iOS" | Ensure minimum iOS 13.0, rebuild Pods: `cd ios && pod install && cd ..` |
| "No audio on device" | Check RECORD_AUDIO & MODIFY_AUDIO_SETTINGS permissions |
| "App crashes on startup" | Verify minSdkVersion is 21+ on Android |

---

## Quick Verification Checklist

- [ ] Android minSdkVersion = 21+
- [ ] iOS minimum deployment target = 13.0+
- [ ] `RECORD_AUDIO` permission added
- [ ] `INTERNET` permission added
- [ ] `NSMicrophoneUsageDescription` added (iOS)
- [ ] `flutter pub get` completed
- [ ] Device shows "Registered" in app
- [ ] Can make outbound call without errors
- [ ] Receive test call successfully

---

## Support

- [Flutter Permissions](https://pub.dev/packages/permission_handler)
- [Flutter WebRTC](https://pub.dev/packages/flutter_webrtc)
- [Vobiz Documentation](https://docs.vobiz.ai)
- GitHub Issues: [vobiz-flutter-sdk](https://github.com/vobiz-ai/vobiz-flutter-sdk/issues)
