package app.unison

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: UnisonBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = UnisonBridge(this, flutterEngine.dartExecutor.binaryMessenger).also { it.onLink(intent?.data) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        bridge?.onLink(intent.data)
    }

    override fun onResume() {
        super.onResume()
        bridge?.setVisible(true)
    }

    override fun onPause() {
        bridge?.setVisible(false)
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
