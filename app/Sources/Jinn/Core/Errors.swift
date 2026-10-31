import Foundation

struct JinnError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }

    static func stale(_ app: String) -> JinnError { .init("that element no longer exists; call app_state for \(app) again and use the new indices") }
    static func blocked(_ what: String) -> JinnError { .init("blocked for safety: \(what)") }
    static func permission(_ what: String) -> JinnError { .init("\(what) not granted: System Settings > Privacy & Security > enable Jinn") }
    static let declined = JinnError("the user declined this action")
}

/// Error text for the model and the user; macOS folder-privacy denials say how to fix them.
func explain(_ e: Error) -> String {
    let ns = e as NSError
    if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
        return JinnError.permission("Files and Folders access (or Full Disk Access)").message
    }
    return e.localizedDescription
}
