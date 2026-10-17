import CryptoTokenKit
import Flutter
import Foundation

/// The CatCard's CCID smart-card reader, reached through CryptoTokenKit.
///
/// iOS gives an app no USB API, but it drives any class-compliant CCID reader
/// on the USB-C (or Lightning adapter) port and lets an app exchange APDUs
/// with the card in it. CatCard presents such a reader beside its vendor HID
/// interface (catcard `docs/PHONE-APP.md`). This class is the whole bridge:
/// it names the readers, powers the card on, forwards one APDU at a time and
/// tells Dart when readers come and go. Every protocol byte is built in Dart.
final class CatCardChannel: NSObject, FlutterStreamHandler {
  private static let methodName = "net.tibane.tibaneapp/catcard"
  private static let eventsName = "net.tibane.tibaneapp/catcard/readers"

  /// Kept alive for the life of the engine.
  static var shared: CatCardChannel?

  private let manager = TKSmartCardSlotManager.default
  private var card: TKSmartCard?
  private var observation: NSKeyValueObservation?
  private var sink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CatCardChannel()
    let method = FlutterMethodChannel(
      name: methodName, binaryMessenger: registrar.messenger())
    method.setMethodCallHandler(instance.handle)
    let events = FlutterEventChannel(
      name: eventsName, binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    shared = instance
  }

  /// The slots whose name says CatCard: the reader is named after the USB
  /// product string.
  private func readerNames() -> [String] {
    guard let manager = manager else { return [] }
    return manager.slotNames.filter { $0.localizedCaseInsensitiveContains("catcard") }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(manager != nil)
    case "listReaders":
      result(readerNames())
    case "open":
      open(call, result: result)
    case "transmit":
      transmit(call, result: result)
    case "close":
      card?.endSession()
      card = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let manager = manager else {
      result(
        FlutterError(
          code: "UNSUPPORTED",
          message: "Smart-card readers are not available on this device.",
          details: nil))
      return
    }
    let args = call.arguments as? [String: Any]
    let wanted = args?["name"] as? String
    guard let name = wanted ?? readerNames().first else {
      result(FlutterError(code: "NO_DEVICE", message: "No CatCard is plugged in.", details: nil))
      return
    }
    card?.endSession()
    card = nil
    manager.getSlot(withName: name) { slot in
      guard let slot = slot, let card = slot.makeSmartCard() else {
        DispatchQueue.main.async {
          result(
            FlutterError(code: "NO_DEVICE", message: "The CatCard reader went away.", details: nil))
        }
        return
      }
      card.beginSession { ok, error in
        DispatchQueue.main.async {
          guard ok else {
            result(
              FlutterError(
                code: "IO",
                message: error?.localizedDescription
                  ?? "Could not start a session with the CatCard.",
                details: nil))
            return
          }
          self.card = card
          let atr = slot.atr?.bytes ?? Data()
          result(["name": name, "atr": FlutterStandardTypedData(bytes: atr)])
        }
      }
    }
  }

  private func transmit(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let card = card else {
      result(FlutterError(code: "NO_DEVICE", message: "The CatCard is not open.", details: nil))
      return
    }
    guard let args = call.arguments as? [String: Any],
      let apdu = args["apdu"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "BAD_ARGS", message: "transmit needs an APDU.", details: nil))
      return
    }
    card.transmit(apdu.data) { response, error in
      DispatchQueue.main.async {
        if let response = response {
          result(FlutterStandardTypedData(bytes: response))
        } else {
          result(
            FlutterError(
              code: "IO",
              message: error?.localizedDescription ?? "The CatCard did not answer.",
              details: nil))
        }
      }
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    observation = manager?.observe(\.slotNames, options: [.initial, .new]) { [weak self] _, _ in
      guard let self = self else { return }
      DispatchQueue.main.async { self.sink?(self.readerNames()) }
    }
    if observation == nil { events([]) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observation = nil
    sink = nil
    return nil
  }
}
