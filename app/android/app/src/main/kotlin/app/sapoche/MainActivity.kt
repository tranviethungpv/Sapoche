package app.sapoche

import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs

class MainActivity : FlutterActivity() {

    private var bridge: SapocheBridge? = null

    /**
     * Impeller needs Vulkan 1.1; without it it draws with OpenGL ES, and there the first frame compiles its pipelines for
     * half a second with the UI thread waiting (measured on a phone-sized emulator: the app opens in 0.75 s with Skia,
     * 1.2 s with Impeller). Those phones use Skia, which is still in the engine.
     */
    override fun getFlutterShellArgs(): FlutterShellArgs = super.getFlutterShellArgs().also { args ->
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION, VULKAN_1_1)) {
            args.add("--enable-impeller=false")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = SapocheBridge(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer).also { it.onLink(intent?.data); it.onOpenChat(intent) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        bridge?.onLink(intent.data)
        bridge?.onOpenChat(intent)
    }

    @Deprecated("The file picker answers through the framework callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        bridge?.onActivityResult(requestCode, resultCode, data)
    }

    @Deprecated("The permission dialog answers through the framework callback")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        SapocheApp.deviceMusic.onPermissionResult(requestCode)
        bridge?.onNoticePermission(requestCode, grantResults)
    }

    /** Rotation and other changes are handled here without recreating the activity; note when they happen. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        EventLog.d("ui", "configuration changed: orientation=${newConfig.orientation} size=${newConfig.screenWidthDp}x${newConfig.screenHeightDp}dp")
        super.onConfigurationChanged(newConfig)
    }

    override fun onResume() {
        super.onResume()
        bridge?.setVisible(true)
    }

    override fun onPause() {
        // In the small window over other apps the picture is still seen
        if (!isInPictureInPictureMode) bridge?.setVisible(false)
        EventLog.flush()
        super.onPause()
    }

    override fun onStop() {
        // The small window was closed, or the app left while in it
        bridge?.setVisible(false)
        super.onStop()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        bridge?.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        bridge?.onPictureInPictureChanged(isInPictureInPictureMode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private companion object {
        /** `FEATURE_VULKAN_HARDWARE_VERSION` encodes 1.1 as (1 shl 22) or (1 shl 12). */
        const val VULKAN_1_1 = 0x401000
    }
}
