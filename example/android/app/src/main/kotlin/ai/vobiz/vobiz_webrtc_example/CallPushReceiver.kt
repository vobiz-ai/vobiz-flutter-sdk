package ai.vobiz.vobiz_webrtc_example

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives the push bridge's Firebase data messages directly (the same
 * broadcast firebase_messaging's own receiver listens to), and hands calls to
 * [CallEngine]: the one engine that shows the call screen and signs in.
 *
 * Only the bridge's own types are taken; anything else is left to Firebase.
 */
class CallPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        val type = extras.getString("type") ?: return
        if (type != "incoming_call" && type != "call_ended" && type != "cancel") return
        val data = HashMap<String, String>()
        for (key in extras.keySet()) {
            if (key.startsWith("google.") || key.startsWith("gcm.") || key == "from" || key == "collapse_key") continue
            val value = extras.getString(key) ?: continue
            data[key] = value
        }
        CallEngine.deliverPush(context, data)
    }
}
