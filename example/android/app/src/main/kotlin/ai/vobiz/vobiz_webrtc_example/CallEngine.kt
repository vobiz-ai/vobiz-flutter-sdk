package ai.vobiz.vobiz_webrtc_example

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app's one Flutter engine. It runs the SIP connection and the UI
 * together, and outlives MainActivity.
 *
 * A push for a call starts it headless when the app is closed
 * ([CallPushReceiver]), so the Dart side shows the call screen and signs in
 * while the phone is still ringing. Accept then opens MainActivity on this
 * same engine: no second engine, no second SIP connection, no Firebase or
 * call-screen background engines (the Dart side registers no background
 * handlers).
 *
 * The method channel `ai.vobiz.example/call` (Dart: CallPlatform):
 *  - Dart -> Android: ready, startCallService, stopCallService, leaveLockScreen,
 *    showMissedCall
 *  - Android -> Dart: push(data), hangUp()
 */
object CallEngine {
    private const val TAG = "VobizCallEngine"
    const val ENGINE_ID = "vobiz_call_engine"
    const val CHANNEL = "ai.vobiz.example/call"
    private const val MISSED_CHANNEL = "vobiz_missed_calls"

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    /** Dart called `ready`: pushes can be delivered straight away. */
    private var dartReady = false

    /** Pushes that arrived before Dart was listening. */
    private val pending = mutableListOf<Map<String, String>>()

    /** The engine, started (running `main()`) if it is not running yet. Main thread only. */
    @JvmStatic
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)

        val engine = FlutterEngine(app)
        val methods = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methods.setMethodCallHandler { call, result -> onMethodCall(app, call, result) }
        channel = methods
        dartReady = false
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {
                dartReady = false
            }

            override fun onEngineWillDestroy() {
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
                channel = null
                dartReady = false
            }
        })
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        Log.d(TAG, "Started the call engine")
        return engine
    }

    /** A call push: hand it to Dart, starting the engine if needed. */
    @JvmStatic
    fun deliverPush(context: Context, data: Map<String, String>) {
        main.post {
            obtain(context)
            val methods = channel
            if (dartReady && methods != null) {
                methods.invokeMethod("push", data)
            } else {
                pending.add(data)
            }
        }
    }

    /** "Hang up" on the ongoing-call notification. */
    @JvmStatic
    fun requestHangUp() {
        main.post { channel?.invokeMethod("hangUp", null) }
    }

    private fun onMethodCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ready" -> {
                    dartReady = true
                    val queued = pending.toList()
                    pending.clear()
                    result.success(queued)
                }
                "startCallService" -> {
                    CallService.start(
                        context,
                        call.argument<String>("caller") ?: "",
                        call.argument<Boolean>("outbound") ?: false,
                    )
                    result.success(null)
                }
                "stopCallService" -> {
                    // The call is over: so is showing over the lock screen.
                    CallService.stop(context)
                    MainActivity.leaveLockScreen()
                    result.success(null)
                }
                "leaveLockScreen" -> {
                    // An accepted call screen led to no call; a running call keeps it.
                    if (!CallService.running) MainActivity.leaveLockScreen()
                    result.success(null)
                }
                "showMissedCall" -> {
                    showMissedCall(
                        context,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("caller") ?: "Unknown caller",
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException, SecurityException …
            Log.w(TAG, "${call.method} failed", e)
            result.error("call_platform", e.message, null)
        }
    }

    private fun showMissedCall(context: Context, id: String, caller: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(MISSED_CHANNEL, "Missed calls", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val tap = open?.let {
            PendingIntent.getActivity(
                context, id.hashCode(), it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, MISSED_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.sym_call_missed)
            .setContentTitle("Missed call")
            .setContentText(caller)
            .setCategory(Notification.CATEGORY_MISSED_CALL)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        // One notification per call: a second report of the same call replaces it.
        manager.notify("missed", id.hashCode(), notification)
    }

    /** Opens the app on this engine (from the ongoing-call notification). */
    fun openAppIntent(context: Context): PendingIntent? {
        val open: Intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        return PendingIntent.getActivity(
            context, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
