import Flutter
import StoreKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Expose the user's App Store storefront country to Dart via a
    // narrow MethodChannel — avoids pulling in the full
    // in_app_purchase package just to read SKStorefront. The returned
    // value is an ISO 3166-1 alpha-3 code (e.g. "GBR", "USA") and is
    // what Apple expects regional compliance gates to key on. Returns
    // nil when the device is signed out of the App Store or StoreKit
    // hasn't populated storefront yet.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TibaneStorefront")
    let channel = FlutterMethodChannel(
      name: "net.tibane.tibaneapp/storefront",
      binaryMessenger: registrar!.messenger()
    )
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "countryCode":
        if let storefront = SKPaymentQueue.default().storefront {
          result(storefront.countryCode)
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
