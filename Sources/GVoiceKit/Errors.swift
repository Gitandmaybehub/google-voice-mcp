import Foundation

/// Every failure the tool reports. `code` is stable for agents; `message` and `hint` are for people.
public struct GVError: Error, CustomStringConvertible, Equatable {
    public let code: String
    public let message: String
    public var hint: String?
    public var exitCode: Int32

    public init(_ code: String, _ message: String, hint: String? = nil, exitCode: Int32 = 1) {
        self.code = code
        self.message = message
        self.hint = hint
        self.exitCode = exitCode
    }

    public var description: String { hint.map { "\(message) \($0)" } ?? message }

    public var json: [String: Any] {
        var e: [String: Any] = ["code": code, "message": message]
        if let hint { e["hint"] = hint }
        return e
    }

    public static func invalid(_ message: String) -> GVError {
        GVError("INVALID_ARGUMENT", message, exitCode: 2)
    }

    public static let signedOut = GVError(
        "SIGNED_OUT", "Google Voice is not signed in.",
        hint: "Run `gvoice login` and sign in to the Google account that owns the Voice number.", exitCode: 3)

    public static let sessionExpired = GVError(
        "SIGNED_OUT", "Google ended this sign-in (expired, signed out, or password changed).",
        hint: "Run `gvoice login` to sign in again.", exitCode: 3)

    public static func notFound(_ what: String) -> GVError {
        GVError("NOT_FOUND", "\(what) was not found in Google Voice.")
    }

    public static let rateLimited = GVError(
        "RATE_LIMITED", "Google Voice asked us to slow down.", hint: "Wait a minute and try again.")

    public static func network(_ detail: String) -> GVError {
        GVError("NETWORK", "Could not reach Google Voice (\(detail)).", hint: "Check the internet connection and try again.")
    }

    public static func google(_ status: Int, _ detail: String) -> GVError {
        GVError("GOOGLE_ERROR", "Google Voice returned an error (HTTP \(status))\(detail.isEmpty ? "" : ": \(detail)").")
    }
}
