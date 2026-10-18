import Flutter
import UIKit

/// Flutter plugin that bridges the Dart `OwnerIdentityStore` API to the
/// iOS Keychain via [KeychainSyncStore].
///
/// Method channel: `remote_pi_identity`
///   - `load` → returns `FlutterStandardTypedData(bytes:)` or nil
///   - `save({ blob: Uint8List })` → void
///   - `delete` → void (idempotent)
///   - `isSyncAvailable` → Bool
///
/// Event channel: `remote_pi_identity/events`
///   - Emits the blob whenever it changes. iOS triggers come from two
///     sources combined: `NSUbiquitousKeyValueStore` external-change
///     notifications and a foreground-poll fallback (Keychain itself
///     has no change observer). De-dup is done by comparing bytes.
public class RemotePiIdentityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let store = KeychainSyncStore()
    private var eventSink: FlutterEventSink?
    private var lastEmittedBlob: Data?
    private var foregroundObserver: NSObjectProtocol?
    private var iCloudObserver: NSObjectProtocol?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RemotePiIdentityPlugin()
        let method = FlutterMethodChannel(
            name: "remote_pi_identity",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: method)

        let event = FlutterEventChannel(
            name: "remote_pi_identity/events",
            binaryMessenger: registrar.messenger()
        )
        event.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "load":
            handleLoad(result: result)
        case "save":
            handleSave(call: call, result: result)
        case "delete":
            handleDelete(result: result)
        case "isSyncAvailable":
            result(store.isSyncAvailable())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleLoad(result: @escaping FlutterResult) {
        if !store.isSyncAvailable() {
            result(syncUnavailableError("iCloud Keychain is not enabled on this device"))
            return
        }
        do {
            if let data = try store.load() {
                result(FlutterStandardTypedData(bytes: data))
            } else {
                result(nil)
            }
        } catch let KeychainSyncStore.StoreError.osStatus(status, what) {
            result(osStatusError(status, what: what))
        } catch {
            result(unknownError(error))
        }
    }

    private func handleSave(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if !store.isSyncAvailable() {
            result(syncUnavailableError("iCloud Keychain is not enabled on this device"))
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let typed = args["blob"] as? FlutterStandardTypedData
        else {
            result(FlutterError(
                code: "bad_args",
                message: "save: expected { blob: Uint8List }",
                details: nil
            ))
            return
        }
        do {
            try store.save(blob: typed.data)
            // Echo into the event stream so listeners see their own
            // write — UI that subscribes to watch() gets the new value
            // without a separate load().
            emitIfChanged(typed.data)
            result(nil)
        } catch let KeychainSyncStore.StoreError.osStatus(status, what) {
            result(osStatusError(status, what: what))
        } catch {
            result(unknownError(error))
        }
    }

    private func handleDelete(result: @escaping FlutterResult) {
        do {
            try store.delete()
            lastEmittedBlob = nil
            result(nil)
        } catch let KeychainSyncStore.StoreError.osStatus(status, what) {
            result(osStatusError(status, what: what))
        } catch {
            result(unknownError(error))
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        // Initial emit: if we already have a blob cached, push it now
        // so subscribers don't need a separate load() call.
        if store.isSyncAvailable(), let data = try? store.load() {
            emitIfChanged(data)
        }

        // Foreground returns are the primary "maybe sync arrived"
        // signal — Keychain itself has no change observer. We poll
        // on each willEnterForeground.
        let nc = NotificationCenter.default
        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.pollAndEmit() }

        // iCloud key-value store doesn't carry our blob (Keychain does),
        // but its notification is a useful "iCloud surface changed
        // something" tickle that often precedes Keychain sync arriving.
        iCloudObserver = nc.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in self?.pollAndEmit() }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        if let obs = iCloudObserver {
            NotificationCenter.default.removeObserver(obs)
            iCloudObserver = nil
        }
        eventSink = nil
        return nil
    }

    private func pollAndEmit() {
        guard store.isSyncAvailable(), let data = try? store.load() else { return }
        emitIfChanged(data)
    }

    private func emitIfChanged(_ data: Data) {
        if let last = lastEmittedBlob, last == data { return }
        lastEmittedBlob = data
        eventSink?(FlutterStandardTypedData(bytes: data))
    }

    // MARK: - Error mapping

    private func syncUnavailableError(_ reason: String) -> FlutterError {
        return FlutterError(code: "sync_unavailable", message: reason, details: nil)
    }

    private func osStatusError(_ status: OSStatus, what: String) -> FlutterError {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return FlutterError(
            code: "keychain_error",
            message: "\(what): \(description)",
            details: ["osStatus": Int(status)]
        )
    }

    private func unknownError(_ error: Error) -> FlutterError {
        return FlutterError(
            code: "unknown",
            message: error.localizedDescription,
            details: nil
        )
    }
}
