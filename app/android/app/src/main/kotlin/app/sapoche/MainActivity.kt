package app.sapoche

import android.content.Intent
import android.content.res.Configuration
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var bridge: SapocheBridge? = null

    /** The screen says (`steer`) when the volume keys are for another device of the person, and is told (`press`) of each press. */
    private var volumeKeys: MethodChannel? = null
    private var steerVolumeKeys = false

    /** The screen says (`show`, `hide`) when this phone steers another device, and is told (`command`) what the system asks of it. */
    private var remoteSession: MethodChannel? = null

    /**
     * Impeller needs Vulkan 1.1; without it it draws with OpenGL ES, and there the first frame compiles its pipelines for
     * half a second with the UI thread waiting (measured on a phone-sized emulator: the app opens in 0.75 s with Skia,
     * 1.2 s with Impeller). Those phones use Skia, which is still in the engine.
     */
    override fun getFlutterShellArgs(): FlutterShellArgs = super.getFlutterShellArgs().also { args ->
        if (!Heat.hasVulkan11(this)) {
            args.add("--enable-impeller=false")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = SapocheBridge(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer).also { it.onLink(intent?.data); it.onOpenChat(intent) }
        steerVolumeKeys = false
        volumeKeys = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.sapoche/volume_keys").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "steer") {
                    steerVolumeKeys = call.arguments as? Boolean == true
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
        remoteSession = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.sapoche/remote_session").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        RemoteSessionService.commands = { name, args -> channel.invokeMethod("command", mapOf("name" to name) + args) }
                        RemoteSessionService.show(this, RemoteMirror.from(call.arguments as Map<*, *>))
                        result.success(null)
                    }
                    "hide" -> {
                        RemoteSessionService.hide(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * While another device plays, the volume keys are its volume's: taken here, before any view and before the system, so that
     * they do not depend on which view has the focus or on how the engine answers a key (a key that came back from it was
     * given to the system now and then). The press goes to the screen, which asks the other device; held, it repeats.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val up = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP
        if (steerVolumeKeys && (up || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            if (event.action == KeyEvent.ACTION_DOWN) volumeKeys?.invokeMethod("press", if (up) 1 else -1)
            return true
        }
        return super.dispatchKeyEvent(event)
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
        EventLog.k("app", "on the screen")
        bridge?.setVisible(true)
    }

    override fun onPause() {
        // In the small window over other apps the picture is still seen
        if (!isInPictureInPictureMode) bridge?.setVisible(false)
        EventLog.k("app", "left the screen")
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
        steerVolumeKeys = false
        volumeKeys?.setMethodCallHandler(null)
        volumeKeys = null
        // The screen that steered is gone, so nothing would answer the keys
        RemoteSessionService.commands = null
        RemoteSessionService.hide(this)
        remoteSession?.setMethodCallHandler(null)
        remoteSession = null
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
