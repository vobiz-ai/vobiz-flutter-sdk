package ai.vobiz.vobiz_webrtc_example

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import com.hiennv.flutter_callkit_incoming.CallkitConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        // Re-created (after Android killed the process, say), the activity is
        // handed its first intent again: that is not a new Accept.
        showOverLockScreen(savedInstanceState == null && isCallAccept(intent))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showOverLockScreen(isCallAccept(intent))
    }

    override fun onDestroy() {
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    /**
     * Always the app's one engine ([CallEngine]): the one a push may already
     * have started, signed in and ringing. Provided by the host, it is not
     * destroyed with this activity, so a call keeps running when the UI goes.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = CallEngine.obtain(context)

    /** Accept on the incoming-call screen: the plugin opens the app with this action. */
    private fun isCallAccept(intent: Intent?): Boolean = intent?.action == CallkitConstants.ACTION_CALL_ACCEPT

    /**
     * Accept on the incoming-call screen opens the app over the lock screen,
     * so the call can be seen without unlocking, until that call ends
     * ([leaveLockScreen]). Opened any other way, it stays behind the lock
     * screen as usual.
     */
    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        }
    }

    companion object {
        private var current: WeakReference<MainActivity>? = null

        /** The call is over: the app goes back behind the lock screen. Main thread only. */
        fun leaveLockScreen() {
            current?.get()?.showOverLockScreen(false)
        }
    }
}
