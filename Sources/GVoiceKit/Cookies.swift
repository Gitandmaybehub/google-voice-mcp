import CryptoKit
import Foundation

/// One browser cookie, kept with the details needed to decide which requests it belongs to.
public struct Cookie: Codable, Equatable {
    public var name: String
    public var value: String
    public var domain: String      // without a leading dot
    public var hostOnly: Bool      // true = exact host only, false = host and its subdomains
    public var path: String
    public var expires: Date?
    public var secure: Bool

    public init(name: String, value: String, domain: String, hostOnly: Bool = false, path: String = "/",
                expires: Date? = nil, secure: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expires = expires
        self.secure = secure
    }

    public init(_ c: HTTPCookie) {
        name = c.name
        value = c.value
        hostOnly = !c.domain.hasPrefix(".")
        domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
        path = c.path.isEmpty ? "/" : c.path
        expires = c.expiresDate
        secure = c.isSecure
    }

    public func applies(to url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires, expires < now { return false }
        if secure && url.scheme != "https" { return false }
        let d = domain.lowercased()
        let hostMatch = hostOnly ? host == d : (host == d || host.hasSuffix("." + d))
        guard hostMatch else { return false }
        let p = url.path.isEmpty ? "/" : url.path
        return p == path || p.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    var key: String { "\(name)|\(domain)|\(path)" }
}

public struct CookieJar: Codable, Equatable {
    public var cookies: [Cookie] = []

    public init(_ cookies: [Cookie] = []) {
        self.cookies = cookies
    }

    /// Cookies that Google refreshes on almost every response. Saving them each time would only churn the file.
    static let noisy: Set<String> = ["SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC"]

    public func header(for url: URL) -> String? {
        let now = Date()
        let picked = cookies.filter { $0.applies(to: url, now: now) }
            .sorted { $0.path.count > $1.path.count }
        return picked.isEmpty ? nil : picked.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The value for a Google-wide cookie such as SAPISID.
    public func value(_ name: String) -> String? {
        cookies.first { $0.name == name && ($0.domain == "google.com" || $0.domain.hasSuffix(".google.com")) }?.value
            ?? cookies.first { $0.name == name }?.value
    }

    public mutating func set(_ c: Cookie) {
        cookies.removeAll { $0.key == c.key }
        if let exp = c.expires, exp < Date() { return }
        cookies.append(c)
    }

    /// Applies Set-Cookie headers from a response. Returns the cookies that changed in a way worth saving.
    @discardableResult
    public mutating func absorb(_ response: HTTPURLResponse) -> [Cookie] {
        guard let url = response.url else { return [] }
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String, let v = v as? String { fields[k] = v }
        }
        var changed: [Cookie] = []
        for http in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let c = Cookie(http)
            let old = cookies.first { $0.key == c.key }
            set(c)
            if old?.value != c.value || (old != nil && c.expires.map { $0 < Date() } == true) {
                if !CookieJar.noisy.contains(c.name) { changed.append(c) }
            }
        }
        return changed
    }

    public mutating func dropExpired(now: Date = Date()) {
        cookies.removeAll { $0.expires.map { $0 < now } ?? false }
    }
}

public enum GoogleAuth {
    /// The header Google's own web apps send: SHA-1 over "timestamp SAPISID origin".
    public static func sapisidHash(_ sapisid: String, origin: String, at date: Date = Date()) -> String {
        let ts = Int(date.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }
}
