package app.operit

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exposes active notifications only after Android grants notification-listener access. */
class OperitNotificationListener : NotificationListenerService() {
    companion object {
        private val connectionLock = Any()
        private var listener: OperitNotificationListener? = null
        private val connectionWaiters = mutableSetOf<CountDownLatch>()

        /** Reports the actual Android notification-listener authorization state. */
        fun isAuthorized(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context).any { it == context.packageName }

        /** Reads active system notifications from the authorized listener connection. */
        fun read(activity: MainActivity, limit: Int, includeOngoing: Boolean): Map<String, Any> {
            require(limit > 0) { "Notification limit must be positive" }
            val ready = CountDownLatch(1)
            synchronized(connectionLock) {
                connectionWaiters.add(ready)
                if (listener != null) ready.countDown()
            }
            try {
                if (!isAuthorized(activity)) {
                    activity.runOnUiThread {
                        activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    }
                }
                check(ready.await(60, TimeUnit.SECONDS)) {
                    "Notification access was not granted or its listener did not connect"
                }
                check(isAuthorized(activity)) { "Notification listener access is not authorized" }
                val connected = synchronized(connectionLock) { listener }
                    ?: error("The notification listener disconnected")
                val notifications = connected.activeNotifications
                    .filter { includeOngoing || !it.isOngoing }
                    .sortedByDescending { it.postTime }
                    .take(limit)
                    .map { entry ->
                        val extras = entry.notification.extras
                        val text = listOfNotNull(
                            extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
                            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
                        ).distinct().joinToString("\n")
                        mapOf("packageName" to entry.packageName, "text" to text,
                            "timestamp" to entry.postTime)
                    }
                return mapOf("notifications" to notifications, "timestamp" to System.currentTimeMillis())
            } finally {
                synchronized(connectionLock) { connectionWaiters.remove(ready) }
            }
        }
    }

    /** Publishes the live listener and releases requests awaiting user authorization. */
    override fun onListenerConnected() {
        super.onListenerConnected()
        synchronized(connectionLock) {
            listener = this
            connectionWaiters.forEach { it.countDown() }
        }
    }

    /** Removes a disconnected listener so future reads cannot use a stale service. */
    override fun onListenerDisconnected() {
        synchronized(connectionLock) { if (listener === this) listener = null }
        super.onListenerDisconnected()
    }

    /** Clears the service reference when Android destroys the notification listener. */
    override fun onDestroy() {
        synchronized(connectionLock) { if (listener === this) listener = null }
        super.onDestroy()
    }
}
