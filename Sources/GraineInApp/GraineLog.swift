import Foundation
import os.log

/// The SDK's log, under the subsystem "ai.graine.inapp" — filter on it in Console or Xcode.
enum GraineLog {
    private static let log = OSLog(subsystem: "ai.graine.inapp", category: "Graine")

    /// Bridge traffic and the page's console. Only ever called with `debug` on.
    static func trace(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
    }

    static func warning(_ message: String) {
        os_log("%{public}@", log: log, type: .error, "warning: " + message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }
}
