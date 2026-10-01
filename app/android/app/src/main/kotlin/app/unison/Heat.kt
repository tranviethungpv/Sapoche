package app.unison

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Whether the phone is warm or short of power, and so should be left alone: work that nobody is waiting for
 * (downloads of liked songs, refreshing suggestions, fetching an update) is put off, and the screen moves its
 * small parts more slowly. Playing music and what the person asked for just now carry on.
 *
 * "Warm" is the system's own thermal status at moderate or above (Android 10 and later); "short of power" is
 * the battery saver. Both are reported by the system when they change, so nothing here polls.
 */
class Heat(private val context: Context) {
    private val power = context.getSystemService(PowerManager::class.java)
    private val calmFlow = MutableStateFlow(read())

    /** True while the phone is warm or in battery saver. */
    val calm: StateFlow<Boolean> get() = calmFlow

    init {
        if (Build.VERSION.SDK_INT >= 29) {
            power.addThermalStatusListener(context.mainExecutor) { update() }
        }
        context.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = update()
            },
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
        )
    }

    private fun update() {
        val now = read()
        if (now != calmFlow.value) EventLog.d("heat", if (now) "calm: warm or saving power" else "calm over")
        calmFlow.value = now
    }

    private fun read(): Boolean {
        val warm = Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE
        return warm || power.isPowerSaveMode
    }
}
