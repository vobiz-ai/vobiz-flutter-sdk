package ai.vobiz.vobiz_webrtc_example

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * The foreground service for a call, inbound or outbound, however it was
 * answered: it keeps the microphone working and the process running when
 * the app goes to the background or the screen locks. Without it Android
 * silences the microphone in the background and the far end hears nothing,
 * while the call keeps running (and billing).
 *
 * Types phoneCall|microphone (Android 14 needs a type; microphone needs
 * RECORD_AUDIO granted and must be started while the app is visible, or
 * right after the user's tap). The ongoing-call notification has Hang up.
 *
 * It belongs to the app, not to the call-screen plugin: closing a call
 * screen (a second call, a timeout) never stops it.
 */
class CallService : Service() {
    companion object {
        private const val TAG = "VobizCallService"
        private const val CHANNEL_ID = "vobiz_ongoing_call"
        private const val NOTIFICATION_ID = 7301
        private const val ACTION_HANG_UP = "ai.vobiz.vobiz_webrtc_example.HANG_UP"
        private const val EXTRA_CALLER = "caller"
        private const val EXTRA_OUTBOUND = "outbound"

        fun start(context: Context, caller: String, outbound: Boolean) {
            val intent = Intent(context, CallService::class.java)
                .putExtra(EXTRA_CALLER, caller)
                .putExtra(EXTRA_OUTBOUND, outbound)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANG_UP) {
            CallEngine.requestHangUp()
            return START_NOT_STICKY
        }
        val caller = intent?.getStringExtra(EXTRA_CALLER).orEmpty()
        val outbound = intent?.getBooleanExtra(EXTRA_OUTBOUND, false) ?: false
        val notification = buildNotification(caller, outbound)
        if (!goForeground(notification)) {
            stopSelf()
        }
        // A call cannot be resumed after the process dies: do not restart.
        return START_NOT_STICKY
    }

    /** startForeground with phoneCall|microphone, then phoneCall alone. */
    private fun goForeground(notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return true
        }
        val types = mutableListOf<Int>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            types.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        }
        types.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        for (type in types) {
            try {
                startForeground(NOTIFICATION_ID, notification, type)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "startForeground(type=$type) refused", e)
            }
        }
        return false
    }

    private fun buildNotification(caller: String, outbound: Boolean): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Ongoing calls", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val hangUp = PendingIntent.getService(
            this, 1,
            Intent(this, CallService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        @Suppress("DEPRECATION")
        val hangUpAction = Notification.Action.Builder(android.R.drawable.sym_call_outgoing, "Hang up", hangUp).build()
        return builder
            .setSmallIcon(if (outbound) android.R.drawable.sym_call_outgoing else android.R.drawable.sym_call_incoming)
            .setContentTitle(if (caller.isEmpty()) "Vobiz call" else caller)
            .setContentText("On a call")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(CallEngine.openAppIntent(this))
            .addAction(hangUpAction)
            .build()
    }
}
