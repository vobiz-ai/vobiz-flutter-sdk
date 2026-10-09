# Credentials: what to enter, and where to find it

Nothing is compiled into the SDK or the example app. Whoever uses the app enters their
own values, in one of two ways.

## Zero-Config Setup: Auth ID and Auth Token

1. Sign in to the Vobiz Console.
2. Copy the **Auth ID** (it looks like `MA_XXXXXXXX`) and the **Auth Token** from the
   dashboard. The Auth Token is not your login password.
3. Enter both on the Zero-Config Setup tab, or pass them to
   `connectWithAuthToken(authId:, authToken:)`.

The webhook server then finds or creates two things on your account and the SDK signs
in as the endpoint:

| Created on your account | Name |
|---|---|
| Application, answer URL `<webhook>/api/answer` | `Vobiz WebRTC Playground` |
| SIP endpoint attached to it, with a new password each sign-in | alias `Vobiz WebRTC Playground Endpoint`, username `play…` |

These are the same ones the web Playground uses. Signing in from the app therefore
gives the endpoint a new password, and a session elsewhere that signed in with the old
one stops working at its next refresh.

## SIP Direct: an endpoint's username and password

1. In the Vobiz Console, open **Voice → Endpoints** and create (or pick) an endpoint.
2. Attach it to an application whose answer URL decides what calls do. The
   application Zero-Config creates (`Vobiz WebRTC Playground`, answer URL
   `https://rtc-demo.vobiz.ai/api/answer`) works.
3. Save the password when you create the endpoint: it is shown once.
4. Enter the username (such as `play123456…`) and password on the SIP Direct tab, or
   pass them in a `CredentialConfig`.

SIP Direct sends no account credentials anywhere, and so cannot transfer calls.

## Caller ID

Calls to phones need a caller ID the account owns: a number bought from Vobiz
(**Voice → Numbers**) or your trial number, in E.164 form such as `+918000000000`.
A number the account does not own fails at once, with no B leg.

## Receiving calls

1. In **Voice → Numbers**, attach your number to the `Vobiz WebRTC Playground`
   application.
2. Sign in with **Zero-Config Setup** at least once. The hosted server learns which
   endpoint to ring for your account at that moment, and keeps it in memory: after the
   server restarts, sign in with Zero-Config again before expecting incoming calls.

## Keep them out of source control

Never commit an Auth Token, an endpoint password or a real number. If an Auth Token
has been committed or shared, rotate it in the Vobiz Console: removing it from the
files does not remove it from git history.

The live sign-in test (`example/integration_test`) takes its credentials from
`--dart-define-from-file`, never from the code. See [example/README.md](example/README.md).
