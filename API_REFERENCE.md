# Vobiz WebRTC SDK - Complete API Reference

This document describes all public APIs in the Vobiz WebRTC SDK for Flutter.

---

## Core Classes

### VobizClient

The main entry point for the SDK. Manages SIP registration, call lifecycle, and WebRTC connections.

**Constructor:**
```dart
VobizClient({
  required SdkConfig config,
  VobizClientListener? listener,
})
```

**Methods:**

#### `login()`
Registers with the SIP server using credentials.

```dart
Future<void> login({
  required String username,    // SIP username from Vobiz Console
  required String password,    // SIP password
  bool autoReconnect = true,   // Auto-reconnect on network drop
})
```

**Throws:** `Exception` if registration fails

**Example:**
```dart
await client.login(
  username: 'dkvoice312279403969368799244',
  password: 'your-sip-password',
);
```

---

#### `logout()`
Unregisters from SIP server and closes all connections.

```dart
Future<void> logout()
```

**Example:**
```dart
await client.logout();
```

---

#### `makeCall()`
Initiates an outbound call to a phone number.

```dart
Future<OutgoingCall> makeCall(String destination)
```

**Parameters:**
- `destination` (String): Phone number in E.164 format (e.g., `+919876543210`)

**Returns:** `OutgoingCall` object to control the call

**Throws:** 
- `Exception` if call setup fails
- `Exception` if not logged in

**Example:**
```dart
try {
  final call = await client.makeCall('+919686142855');
  print('Call initiated, SIP Call-ID: ${call.callId}');
} catch (e) {
  print('Call failed: $e');
}
```

---

#### `answerCall()`
Answers an incoming call.

```dart
Future<IncomingCall> answerCall(IncomingCall incomingCall)
```

**Parameters:**
- `incomingCall` (IncomingCall): The call object from `onIncomingCall` event

**Returns:** Updated `IncomingCall` with answer status

**Throws:** `Exception` if answer fails

**Example:**
```dart
client.onIncomingCall = (call) async {
  final answered = await client.answerCall(call);
  print('Call answered: ${answered.callerId}');
};
```

---

#### `rejectCall()`
Rejects an incoming call.

```dart
Future<void> rejectCall(IncomingCall incomingCall)
```

**Parameters:**
- `incomingCall` (IncomingCall): The call object from `onIncomingCall` event

**Example:**
```dart
await client.rejectCall(incomingCall);
```

---

#### `hangupCall()`
Ends an active call (outbound or inbound).

```dart
Future<void> hangupCall({OutgoingCall? call, IncomingCall? incomingCall})
```

**Parameters:** Either `call` (outbound) OR `incomingCall` (inbound)

**Example:**
```dart
// Hangup outbound call
await client.hangupCall(call: outgoingCall);

// Hangup inbound call
await client.hangupCall(incomingCall: incomingCall);
```

---

#### `muteAudio()`
Mutes the microphone during an active call.

```dart
Future<void> muteAudio(OutgoingCall call)
```

**Example:**
```dart
await client.muteAudio(outgoingCall);
print('Microphone muted');
```

---

#### `unmuteAudio()`
Unmutes the microphone during an active call.

```dart
Future<void> unmuteAudio(OutgoingCall call)
```

**Example:**
```dart
await client.unmuteAudio(outgoingCall);
print('Microphone unmuted');
```

---

### SdkConfig

Configuration object for initializing VobizClient.

**Constructor:**
```dart
SdkConfig({
  required String wsUrl,           // WebSocket URL of SIP server
  required String sipServer,       // SIP server hostname
  required String backendUrl,      // Your Answer URL backend
  String? callerId,                // PSTN Caller ID (optional)
  IceConfig? iceConfig,            // ICE/STUN/TURN settings (optional)
  MediaConstraints? mediaConstraints,  // Audio constraints (optional)
  bool debug = false,              // Enable debug logging
})
```

**Example:**
```dart
final config = SdkConfig(
  wsUrl: 'wss://registrar.vobiz.ai:5063/',
  sipServer: 'registrar.vobiz.ai',
  backendUrl: 'https://your-backend.example.com',
  callerId: '+918046733542',
  debug: true,
);

final client = VobizClient(config: config);
```

---

### IceConfig

Configures STUN/TURN servers for WebRTC media connectivity.

**Constructor:**
```dart
IceConfig({
  List<String> stunServers = const [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
  ],
  List<Map<String, dynamic>> turnServers = const [],
  int iceCandidateTimeout = 8000,  // milliseconds
})
```

**Example:**
```dart
final iceConfig = IceConfig(
  stunServers: [
    'stun:stun.l.google.com:19302',
  ],
  turnServers: [
    {
      'urls': ['turn:your-turn-server.com:3478'],
      'username': 'user',
      'credential': 'pass',
    }
  ],
  iceCandidateTimeout: 5000,
);
```

---

### MediaConstraints

Configures audio capture settings.

**Constructor:**
```dart
MediaConstraints({
  bool audio = true,
  bool video = false,
  Map<String, dynamic>? audioConstraints,
})
```

**Example:**
```dart
final constraints = MediaConstraints(
  audio: true,
  video: false,
  audioConstraints: {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  },
);
```

---

## Data Models

### OutgoingCall

Represents an outbound call.

**Properties:**
```dart
String callId              // Unique call ID
String destination         // Destination phone number
CallState state            // Current call state
DateTime startTime         // Call start time
String? hangupReason       // Reason for termination (if ended)
CallStats? stats           // Call statistics
```

**Example:**
```dart
final call = await client.makeCall('+919686142855');
print('Call to: ${call.destination}');
print('State: ${call.state}');
```

---

### IncomingCall

Represents an inbound call.

**Properties:**
```dart
String callId              // Unique call ID
String callerId            // Caller's phone number
CallState state            // Current call state
DateTime receivedTime      // When call was received
String? hangupReason       // Reason for termination
```

**Example:**
```dart
client.onIncomingCall = (call) {
  print('Incoming call from: ${call.callerId}');
  print('Call ID: ${call.callId}');
};
```

---

### CallStats

Statistics about an active call.

**Properties:**
```dart
int audioBytesSent         // Total audio bytes sent
int audioBytesReceived     // Total audio bytes received
int rtt                    // Round-trip time (milliseconds)
String audioCodec          // Codec in use (e.g., "opus")
int packetsLost            // Total packets lost
double jitter              // Network jitter (milliseconds)
```

**Example:**
```dart
final stats = call.stats;
if (stats != null) {
  print('Audio codec: ${stats.audioCodec}');
  print('Jitter: ${stats.jitter}ms');
  print('Packets lost: ${stats.packetsLost}');
}
```

---

## Enums & State

### CallState

Represents the current state of a call.

```dart
enum CallState {
  idle,          // No active call
  calling,       // Outbound call initiated, waiting for response
  ringing,       // Remote phone ringing
  inCall,        // Call connected and media flowing
  ended,         // Call terminated
}
```

**Example:**
```dart
if (call.state == CallState.inCall) {
  print('Call is active');
}
```

---

### ConnectionState

Represents the connection status with the SIP server.

```dart
enum ConnectionState {
  disconnected,  // Not connected
  connecting,    // Attempting connection
  connected,     // Successfully connected
  reconnecting,  // Attempting to reconnect after drop
}
```

**Example:**
```dart
client.onConnectionStateChanged = (state) {
  if (state == ConnectionState.connected) {
    print('✅ Connected to SIP server');
  }
};
```

---

### RegistrationState

Represents the SIP registration status.

```dart
enum RegistrationState {
  unregistered,  // Not registered
  registering,   // Registration in progress
  registered,    // Successfully registered
  failed,        // Registration failed
}
```

---

## Event Listeners

VobizClient supports event callbacks for real-time updates.

### Setting Listeners

```dart
client.onIncomingCall = (call) {
  print('Incoming call from: ${call.callerId}');
};

client.onCallStateChanged = (call, state) {
  print('Call state: $state');
};

client.onConnectionStateChanged = (state) {
  print('Connection state: $state');
};

client.onRegistrationStateChanged = (state) {
  print('Registration state: $state');
};

client.onError = (error) {
  print('Error: $error');
};
```

---

## Complete Example

```dart
import 'package:flutter/material.dart';
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late VobizClient _client;
  IncomingCall? _incomingCall;
  OutgoingCall? _outgoingCall;

  @override
  void initState() {
    super.initState();
    _initializeClient();
  }

  void _initializeClient() {
    final config = SdkConfig(
      wsUrl: 'wss://registrar.vobiz.ai:5063/',
      sipServer: 'registrar.vobiz.ai',
      backendUrl: 'https://your-backend.example.com',
      callerId: '+918046733542',
      debug: true,
    );

    _client = VobizClient(config: config);

    // Setup listeners
    _client.onIncomingCall = (call) {
      setState(() => _incomingCall = call);
    };

    _client.onCallStateChanged = (call, state) {
      print('Call state: $state');
    };

    _client.onConnectionStateChanged = (state) {
      print('Connection: $state');
    };

    // Login
    _login();
  }

  Future<void> _login() async {
    try {
      await _client.login(
        username: 'dkvoice312279403969368799244',
        password: 'your-password',
      );
      print('✅ Logged in and registered');
    } catch (e) {
      print('❌ Login failed: $e');
    }
  }

  Future<void> _makeCall(String number) async {
    try {
      final call = await _client.makeCall(number);
      setState(() => _outgoingCall = call);
    } catch (e) {
      print('❌ Call failed: $e');
    }
  }

  Future<void> _answerIncoming() async {
    if (_incomingCall != null) {
      await _client.answerCall(_incomingCall!);
    }
  }

  Future<void> _hangup() async {
    if (_outgoingCall != null) {
      await _client.hangupCall(call: _outgoingCall);
    }
    if (_incomingCall != null) {
      await _client.hangupCall(incomingCall: _incomingCall);
    }
  }

  @override
  void dispose() {
    _client.logout();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Vobiz Call')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_incomingCall != null)
                Column(
                  children: [
                    Text('Incoming call from: ${_incomingCall!.callerId}'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _answerIncoming,
                      child: const Text('Answer'),
                    ),
                  ],
                )
              else
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: () => _makeCall('+919686142855'),
                      child: const Text('Call'),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _hangup,
                      child: const Text('Hangup'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

## Error Handling

All methods may throw exceptions. Common errors:

| Error | Cause |
|-------|-------|
| `"Not logged in"` | Call made before `login()` completed |
| `"Connection failed"` | Network issue or server unreachable |
| `"Registration failed"` | Invalid credentials |
| `"Invalid destination"` | Phone number format invalid |
| `"WebRTC connection failed"` | Network connectivity issue |

**Best Practice:**
```dart
try {
  await client.makeCall('+919686142855');
} catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Error: $e')),
  );
}
```

---

## Troubleshooting

### "SIP registration failed"
- Check username/password from Vobiz Console
- Verify endpoint is **Active** in Vobiz Console > Voice > Endpoints
- Check internet connectivity

### "Call fails immediately after answer"
- Check RECORD_AUDIO permission is granted
- Verify Answer URL backend is accessible
- Check firewall allows WebRTC media ports

### "One-way audio"
- Check microphone/speaker permissions on device
- Test with different network (WiFi vs cellular)
- Verify STUN server is reachable

### "Cannot hear remote"
- Check speaker volume on device
- Verify audio codec support (opus recommended)
- Check firewall blocks RTP ports

---

## Support

- [SDK Repository](https://github.com/devlume-in/vobiz-flutter-sdk)
- [Issue Tracker](https://github.com/devlume-in/vobiz-flutter-sdk/issues)
- [Vobiz Docs](https://docs.vobiz.ai)
- Email: support@vobiz.ai
