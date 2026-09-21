package vn.p0spike.p0_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

private const val TAG = "P0Spike"

/**
 * Foreground service TỐI GIẢN cho P0: chỉ để tiến trình không bị giết khi màn hình tắt
 * trong lúc test 45-60 phút (prompt P0 nói rõ không cần bản hoàn chỉnh).
 *
 * Có giữ PARTIAL_WAKE_LOCK -> số đo pin ở P0 bao gồm cả wake lock này, cần ghi rõ khi báo cáo.
 */
class SpikeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        isRunning = true
        startForegroundCompat()
        acquireWakeLock()
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) runCatching { it.release() } }
        wakeLock = null
        isRunning = false
        Log.i(TAG, "SpikeService destroyed")
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "P0 spike", NotificationManager.IMPORTANCE_LOW),
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle("P0 spike đang test audio/ASR")
            .setContentText("Đừng tắt app trong lúc đo pin/độ ổn định")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        Log.i(TAG, "SpikeService foreground, type=microphone")
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "P0Spike:capture").also {
            it.acquire()
        }
        Log.i(TAG, "đã giữ PARTIAL_WAKE_LOCK (số đo pin sẽ bao gồm cả phần này)")
    }

    companion object {
        private const val CHANNEL_ID = "p0spike"
        private const val NOTIF_ID = 1001

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(ctx: Context) {
            val intent = Intent(ctx, SpikeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, SpikeService::class.java))
        }
    }
}
