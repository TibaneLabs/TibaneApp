import Flutter
import Foundation
import LocalAuthentication
import Security

final class AppLockPasscodeChannel {
  private var activeContext: LAContext?
  private let queue = DispatchQueue(label: "net.tibane.tibaneapp.app-lock-passcode")

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = AppLockPasscodeChannel()
    let channel = FlutterMethodChannel(
      name: "net.tibane.tibaneapp/app-lock-passcode",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      bridge.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil))
    case "authenticate":
      guard activeContext == nil, let reason = call.arguments as? String, !reason.isEmpty else {
        result(false)
        return
      }
      let context = LAContext()
      context.localizedReason = reason
      context.touchIDAuthenticationAllowableReuseDuration = 0
      activeContext = context
      queue.async {
        let authenticated = Self.verifyPasscode(with: context)
        DispatchQueue.main.async {
          let current = self.activeContext === context
          if current { self.activeContext = nil }
          context.invalidate()
          result(current && authenticated)
        }
      }
    case "cancel":
      let context = activeContext
      activeContext = nil
      context?.invalidate()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func verifyPasscode(with context: LAContext) -> Bool {
    guard let access = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, nil
    ) else { return false }

    // Only a temporary marker is stored. The system verifies the device code.
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "net.tibane.tibaneapp.app-lock-passcode",
      kSecAttrAccount as String: UUID().uuidString,
    ]
    let marker = Data([1])
    let quietContext = LAContext()
    quietContext.interactionNotAllowed = true
    var cleanup = identity
    cleanup[kSecUseAuthenticationContext as String] = quietContext
    var attributes = cleanup
    attributes[kSecAttrAccessControl as String] = access
    attributes[kSecValueData as String] = marker
    guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return false }
    defer { SecItemDelete(cleanup as CFDictionary) }

    var query = identity
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
      && (item as? Data) == marker
  }
}
