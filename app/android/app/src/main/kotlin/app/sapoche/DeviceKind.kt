package app.sapoche

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager

/** What sort of screen this device is. */
object DeviceKind {

    /**
     * A TV or a TV box: the system says so by its UI mode, and a box that is a phone's build with a launcher for TV by the
     * leanback feature. The screen is looked at from across a room and held by a remote, not a hand.
     */
    fun isTelevision(context: Context): Boolean {
        val mode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return mode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }
}
