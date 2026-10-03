import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Links `sapoche://join/CODE` open the app on a room. The native side of the app (the sapoche_native plugin) reads them
  /// from the notification; a link that opened the app may come before it listens, so it is also kept in the defaults.
  private static let openURL = Notification.Name("app.sapoche.openURL")

  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url { pass(url) }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    if let url = URLContexts.first?.url { pass(url) }
  }

  private func pass(_ url: URL) {
    UserDefaults.standard.set(url.absoluteString, forKey: "sapoche.pendingURL")
    NotificationCenter.default.post(name: Self.openURL, object: url)
  }
}
