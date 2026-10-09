# Getting Vobiz Credentials

This guide explains how to get the credentials needed to use the Vobiz WebRTC SDK.

---

## Step 1: Create a Vobiz Account

1. Visit [Vobiz Console](https://app.vobiz.ai)
2. Sign up or log in
3. Complete account verification

---

## Step 2: Purchase a Phone Number

1. Go to **Voice** → **Numbers**
2. Click **"Buy Number"**
3. Choose your country and area code
4. Confirm purchase
5. **Copy the phone number** (e.g., `+91XXXXXXXXXX`)

This is your **CALLER_ID**.

---

## Step 3: Create a SIP Endpoint

1. Go to **Voice** → **Endpoints**
2. Click **"Create Endpoint"**
3. Enter a name (e.g., `My Flutter App`)
4. Vobiz generates:
   - **SIP Username** (e.g., `your-endpoint-username`)
   - **SIP Password** (shown once, save it!)
5. The endpoint URL is: `sip:{username}@registrar.vobiz.ai`

**Save these credentials:**
- `username` = your SIP username
- `password` = your SIP password
- `sipServer` = `registrar.vobiz.ai`

---

## Step 4: Get Your API Keys (Optional, for backend)

1. Go to **Settings** → **API Keys**
2. Copy:
   - **Account SID** (e.g., `MA_XXXXXXXX`)
   - **Auth Token** (e.g., `your-auth-token`)

These are needed for your Answer URL backend server.

---

## Step 5: Configure Your Backend

Your Answer URL backend needs:
- **CALLER_ID** = Your purchased phone number (from Step 2)
- **SIP_ENDPOINT** = Full SIP URI from Step 3
- **VOBIZ_ACCOUNT_SID** & **VOBIZ_AUTH_TOKEN** = From Step 4

See [vobiz-rtc-demo](https://github.com/devlume-in/vobiz-rtc-demo) for server setup.

---

## Step 6: Create Your Voice Application

1. Go to **Voice** → **Applications**
2. Click **"Create Application"**
3. Enter a name (e.g., `My Flutter App`)
4. Set:
   - **Answer URL**: `https://your-public-url.ngrok-free.dev/answer` (your backend)
   - **Hangup URL**: `https://your-public-url.ngrok-free.dev/hangup`
5. Link your phone number from Step 2
6. Save

---

## Step 7: Use Credentials in Your Flutter App

```dart
import 'package:vobiz_webrtc/vobiz_webrtc.dart';

final client = VobizClient(
  config: SdkConfig(
    wsUrl: 'wss://registrar.vobiz.ai:5063/',
    sipServer: 'registrar.vobiz.ai',
    backendUrl: 'https://your-backend.example.com',
  ),
);

// Login with credentials from Step 3
await client.login(
  username: 'your-endpoint-username',  // From Step 3
  password: 'your-password-here',             // From Step 3
);
```

---

## Testing

To test your setup:

1. ✅ Run your Flutter app
2. ✅ Check if it says "Registered"
3. ✅ Call your phone number from Step 2 using another phone
4. ✅ Your app should show an incoming call

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Endpoint not found" | Make sure endpoint is **Active** in Vobiz Console |
| "Authentication failed" | Double-check username and password from Step 3 |
| "No incoming calls" | Verify phone number is linked to application in Step 6 |
| "Answer URL not called" | Check Answer URL in Step 6 is publicly accessible (use ngrok for testing) |

---

## Security Best Practices

⚠️ **Never commit credentials to your code!**

Use environment variables or secure storage:

```dart
// ❌ BAD
await client.login(
  username: 'your-endpoint-username',
  password: 'your-password-here',
);

// ✅ GOOD
final username = dotenv.env['SIP_USERNAME'];
final password = dotenv.env['SIP_PASSWORD'];
await client.login(username: username!, password: password!);
```

Use packages like:
- [flutter_dotenv](https://pub.dev/packages/flutter_dotenv) - For .env files
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) - For encrypted storage

---

## Support

- [Vobiz Documentation](https://docs.vobiz.ai)
- [GitHub Issues](https://github.com/devlume-in/vobiz-flutter-sdk/issues)
- Email: support@vobiz.ai
