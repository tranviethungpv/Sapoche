package app.sapoche

import android.content.Intent
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: SapocheBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = SapocheBridge(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer).also { it.onLink(intent?.data) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        bridge?.onLink(intent.data)
    }

    @Deprecated("The file picker answers through the framework callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        bridge?.onActivityResult(requestCode, resultCode, data)
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
        bridge?.setVisible(false)
        EventLog.flush()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
