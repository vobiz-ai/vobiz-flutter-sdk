package ai.vobiz.vobiz_webrtc_example

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreenWhenAnswering(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showOverLockScreenWhenAnswering(intent)
    }

    /**
     * Always the app's one engine ([CallEngine]): the one a push may already
     * have started, signed in and ringing. Provided by the host, it is not
     * destroyed with this activity, so a call keeps running when the UI goes.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = CallEngine.obtain(context)

    /**
     * Accept on the incoming-call screen opens the app with the call screen's
     * ACTION_CALL_ACCEPT. Only then does the app show over the lock screen,
     * so the call can be seen without unlocking; opened any other way, it
     * stays behind the lock screen as usual.
     */
    private fun showOverLockScreenWhenAnswering(intent: Intent?) {
        val answering = intent?.action?.endsWith("ACTION_CALL_ACCEPT") == true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(answering)
            setTurnScreenOn(answering)
        }
    }
}
