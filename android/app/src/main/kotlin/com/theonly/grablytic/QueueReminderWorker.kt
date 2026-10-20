package com.theonly.grablytic

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.util.concurrent.TimeUnit

/**
 * Background worker for periodic reminders about unprocessed offline queued links.
 *
 * System constraints:
 * - Inexact periodic scheduling via WorkManager (JobScheduler-backed, Doze-aware).
 * - Never touches exact alarms (avoids SCHEDULE_EXACT_ALARM).
 * - Fires ONLY while the offline queue is non-empty.
 * - Automatically cancels itself with WorkManager when the queue empties.
 */
class QueueReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        const val TAG = "QueueReminderWorker"
        const val WORK_NAME = "queue-reminders-poll"
        private const val NOTIF_CHANNEL_REMINDERS = "grablytic_queue_reminders"
        private const val NOTIF_ID = 8815

        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val KEY_QUEUE_REMINDER_ENABLED = "flutter.queueReminderEnabled"
        private const val KEY_OFFLINE_QUEUE_COUNT = "flutter.offlineQueueCount"
        private const val KEY_OFFLINE_LINK_QUEUE = "flutter.grablytic_offline_link_queue"
        private const val LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

        fun schedule(
            context: Context,
            enabled: Boolean,
            intervalMinutes: Long = 180L,
        ) {
            val workManager = WorkManager.getInstance(context)
            if (!enabled) {
                workManager.cancelUniqueWork(WORK_NAME)
                Log.i(TAG, "Cancelled unique work: $WORK_NAME")
                return
            }

            // Inexact scheduling (no SCHEDULE_EXACT_ALARM).
            val constraints = Constraints.Builder()
                .setRequiresBatteryNotLow(true)
                .build()

            val request = PeriodicWorkRequestBuilder<QueueReminderWorker>(
                intervalMinutes.coerceAtLeast(15L),
                TimeUnit.MINUTES,
                15L,
                TimeUnit.MINUTES,
            )
                .setConstraints(constraints)
                .build()

            workManager.enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
            Log.i(TAG, "Enqueued periodic work $WORK_NAME: interval=${intervalMinutes}m")
        }
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        try {
            val prefs = applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean(KEY_QUEUE_REMINDER_ENABLED, false)
            if (!enabled) {
                Log.i(TAG, "Queue reminders disabled in preferences, cancelling worker")
                WorkManager.getInstance(applicationContext).cancelUniqueWork(WORK_NAME)
                return@withContext Result.success()
            }

            val queueCount = readQueueCount(prefs)
            if (queueCount == 0) {
                Log.i(TAG, "Offline link queue is empty, cancelling worker per spec")
                WorkManager.getInstance(applicationContext).cancelUniqueWork(WORK_NAME)
                return@withContext Result.success()
            }
            if (queueCount < 0) {
                // Unreadable preference. That is NOT "the queue is empty":
                // cancelling here would disable reminders for the install
                // because one write was interrupted or one encoding changed.
                // Stay scheduled and try again next interval.
                Log.w(TAG, "Offline queue unreadable; keeping the worker scheduled")
                return@withContext Result.success()
            }

            // Post reminder notification
            postNotification(queueCount)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "Queue reminder check failed: ${e.message}")
            Result.success()
        }
    }

    /**
     * Number of queued offline links, or -1 when the preference cannot be
     * read.
     *
     * Two rules this follows, both learned the hard way:
     *
     * 1. **No Java deserialisation, ever.** This used to fall back to
     *    `ObjectInputStream.readObject()` on a Base64 blob taken out of
     *    SharedPreferences. That is a CWE-502 primitive: `readObject()`
     *    instantiates whatever class the stream names and runs its
     *    `readObject`/`readResolve` hooks, and app-private prefs are
     *    writable by the app itself, restorable from a device backup, and
     *    readable over `adb` on a debuggable build. It was a fallback for
     *    an encoding the Flutter plugin no longer produces, so the whole
     *    branch is gone.
     * 2. **"Unreadable" is not "empty".** Returning 0 for a value that
     *    could not be parsed made `doWork()` cancel the periodic work,
     *    which silently disabled reminders until the app rescheduled it.
     *    The sentinel for that case is -1.
     *
     * The fast path reads the count hint as whatever type is actually
     * stored: Dart's `setInt` arrives over the platform channel as a
     * `Long`, so `getInt` throws `ClassCastException` and never worked.
     */
    private fun readQueueCount(prefs: SharedPreferences): Int {
        readCountHint(prefs)?.let { return it }

        // The plugin has written this key in more than one shape over the
        // years: a Set<String>, a JSON array, and a JSON array behind the
        // legacy list prefix. All three are plain data; none of them needs
        // to be deserialised as a Java object.
        try {
            prefs.getStringSet(KEY_OFFLINE_LINK_QUEUE, null)?.let { return it.size }
        } catch (_: ClassCastException) {
            // stored as a String — handled below
        }

        val raw = try {
            prefs.getString(KEY_OFFLINE_LINK_QUEUE, null)
        } catch (_: ClassCastException) {
            null
        }
        if (raw.isNullOrBlank()) return 0

        val text = raw.trim()
        return when {
            text.startsWith("[") -> countJsonArray(text)
            text.startsWith(LIST_IDENTIFIER) -> {
                val payload = text.substring(LIST_IDENTIFIER.length)
                val body = if (payload.startsWith("!")) payload.substring(1) else payload
                countJsonArray(body)
            }
            // Unknown encoding: report it rather than guessing, and never
            // deserialise it.
            else -> {
                Log.w(TAG, "Unrecognised offline-queue encoding; skipping this run")
                -1
            }
        }
    }

    /** Reads the count hint as Int, Long or String; null when absent. */
    private fun readCountHint(prefs: SharedPreferences): Int? = try {
        when (val value = prefs.all[KEY_OFFLINE_QUEUE_COUNT]) {
            null -> null
            is Int -> value
            is Long -> value.toInt()
            is String -> value.trim().toIntOrNull()
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    /** Array length, or -1 when [text] is not a JSON array. */
    private fun countJsonArray(text: String): Int = try {
        JSONArray(text).length()
    } catch (_: Exception) {
        -1
    }

    private fun ensureReminderChannel() {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = applicationContext.getSystemService(NotificationManager::class.java) ?: return
            if (mgr.getNotificationChannel(NOTIF_CHANNEL_REMINDERS) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        NOTIF_CHANNEL_REMINDERS,
                        "Queue Reminders",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = "Reminders about unprocessed links in offline queue"
                    },
                )
            }
        } catch (_: Exception) {}
    }

    private fun postNotification(count: Int) {
        try {
            ensureReminderChannel()
            if (NotificationManagerCompat.from(applicationContext).areNotificationsEnabled()) {
                val intent = Intent(applicationContext, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra("open_offline_queue", true)
                }
                val pendingIntent = PendingIntent.getActivity(
                    applicationContext,
                    NOTIF_ID,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )

                val contentText = if (count == 1) {
                    "You have 1 queued link waiting to be downloaded."
                } else {
                    "You have $count queued links waiting to be downloaded."
                }

                val notif = NotificationCompat.Builder(applicationContext, NOTIF_CHANNEL_REMINDERS)
                    .setContentTitle("Offline Links Pending")
                    .setContentText(contentText)
                    .setSmallIcon(android.R.drawable.stat_notify_sync)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()

                NotificationManagerCompat.from(applicationContext).notify(NOTIF_ID, notif)
                Log.i(TAG, "Posted queue reminder notification for $count link(s)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post queue reminder notification: ${e.message}")
        }
    }
}
