package app.sapoche

import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRouter2
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.annotation.RequiresApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Where the sound goes. [kind] is `speaker`, `headphones`, `bluetooth`, `airplay`, `car` or `other`; [name] is what the
 * device calls itself, and is empty for the phone's own speaker.
 */
data class AudioOutput(val kind: String, val name: String)

/** Follows where the music is played to and its volume, and opens the system's list of places to play to. */
class AudioOutputs(private val context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val _current = MutableStateFlow(read())
    val current: StateFlow<AudioOutput> = _current

    private val _volume = MutableStateFlow(readVolume())

    /** The volume of the music, 0 to 1; it moves with the buttons of the phone too. */
    val volume: StateFlow<Float> = _volume

    private val volumeWatch = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean) {
            _volume.value = readVolume()
        }
    }

    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = refresh()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = refresh()
    }

    /** Kept to be let go of; a `MediaRouter2.ControllerCallback`, which Android 10 and older do not have. */
    private var routes: Any? = null

    init {
        audio.registerAudioDeviceCallback(devices, main)
        // The system settings change with the volume, buttons or not
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, volumeWatch)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) watchRoutes()
    }

    /** Choosing another of the devices that are already connected adds and removes none, but the system tells the routes. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun watchRoutes() {
        val callback = object : MediaRouter2.ControllerCallback() {
            override fun onControllerUpdated(controller: MediaRouter2.RoutingController) = refresh()
        }
        routes = callback
        MediaRouter2.getInstance(context).registerControllerCallback({ main.post(it) }, callback)
    }

    fun refresh() {
        _current.value = read()
        _volume.value = readVolume()
    }

    /** Sets the volume of the music to [level], 0 to 1, as the buttons of the phone would, without the system's slider. */
    fun setVolume(level: Float) {
        val top = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(level.coerceIn(0f, 1f) * top), 0)
        _volume.value = readVolume()
    }

    private fun readVolume(): Float {
        val top = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return if (top <= 0) 1f else audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / top
    }

    fun release() {
        audio.unregisterAudioDeviceCallback(devices)
        context.contentResolver.unregisterContentObserver(volumeWatch)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            (routes as? MediaRouter2.ControllerCallback)?.let { MediaRouter2.getInstance(context).unregisterControllerCallback(it) }
        }
    }

    /** Opens the system's own list, which also lists what is not connected yet. */
    fun pick() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            MediaRouter2.getInstance(context).showSystemOutputSwitcher()
        ) {
            return
        }
        val panel = Intent("com.android.settings.panel.action.MEDIA_OUTPUT")
            .putExtra("com.android.settings.panel.extra.PACKAGE_NAME", context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val bluetooth = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // The panel is not there on every phone; the Bluetooth settings are
        runCatching { context.startActivity(panel) }.recoverCatching { context.startActivity(bluetooth) }
    }

    private fun read(): AudioOutput {
        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val music = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            audio.getAudioDevicesForAttributes(music).firstOrNull()
        } else {
            // Before that the system does not say; what is plugged in or paired is where it goes, the speaker otherwise
            audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).minByOrNull { rank(it.type) }
        }
        val kind = device?.let { kindOf(it.type) } ?: "speaker"
        return AudioOutput(kind, if (kind == "speaker") "" else device?.productName?.toString().orEmpty())
    }

    private fun kindOf(type: Int) = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_BROADCAST,
        -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET -> "headphones"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker"
        else -> "other"
    }

    /** Lower is what the system would play to first when both are there. */
    private fun rank(type: Int) = when (kindOf(type)) {
        "bluetooth" -> 0
        "headphones" -> 1
        "other" -> 2
        else -> 3
    }
}
