import Foundation

/// Endpoint of a local LM Studio server. Validated to be loopback-only over
/// plain http: `127.0.0.1`, `::1` or `localhost`. Anything else (LAN hosts,
/// hostnames that resolve elsewhere, https, ws, …) is rejected with a clear
/// error. There is no cloud fallback and no telemetry anywhere in this module.
///
/// D01: document content may only ever travel to this explicit loopback server.
public struct LMStudioEndpoint: Hashable, Sendable, CustomStringConvertible {
    public enum EndpointError: Error, Equatable, CustomStringConvertible, Sendable {
        /// The string was not a parsable absolute URL.
        case notAnAbsoluteURL(String)
        /// Only `http` is accepted (LM Studio serves plain http on loopback).
        case schemeNotAllowed(String)
        /// Host is not a permitted loopback host.
        case hostNotAllowed(String)
        /// Credentials, query, fragment or a path were present.
        case unexpectedComponents

        public var description: String {
            switch self {
            case .notAnAbsoluteURL:
                "Ungültige Endpunkt-Adresse. Erwartet wird z. B. „http://127.0.0.1:1234“."
            case .schemeNotAllowed(let scheme):
                "Endpunkt muss http sein (gefunden: „\(scheme.isEmpty ? "kein" : scheme)“). Erlaubt ist ausschließlich ein lokaler http-Endpunkt."
            case .hostNotAllowed(let host):
                "Host „\(host)“ ist nicht erlaubt. Zulässig sind nur lokale Loopback-Adressen: 127.0.0.1, ::1 oder localhost."
            case .unexpectedComponents:
                "Der Endpunkt darf nur Schema, Host und Port enthalten – keine Pfad-, Query-, Fragment- oder Anmeldedaten."
            }
        }
    }

    /// Normalized loopback-only base URL, always http with an empty path, e.g.
    /// `http://127.0.0.1:1234`.
    public let url: URL

    /// Default local LM Studio port.
    public static let defaultPort = 1234

    /// `http://127.0.0.1:1234` – the documented LM Studio default.
    /// Statically known-valid, so the validation cannot fail here.
    public static let localDefault: LMStudioEndpoint = {
        // Statically known-valid; validation cannot fail for this literal.
        try! LMStudioEndpoint(url: URL(string: "http://127.0.0.1:\(defaultPort)")!)
    }()

    /// Validates and normalizes a base URL. See `LMStudioEndpoint`.
    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EndpointError.notAnAbsoluteURL(url.absoluteString)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" else {
            throw EndpointError.schemeNotAllowed(components.scheme ?? "")
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw EndpointError.unexpectedComponents
        }
        guard var host = components.host?.lowercased() else {
            throw EndpointError.hostNotAllowed(components.host ?? "")
        }
        // URLComponents keeps the brackets for IPv6 literals ("[::1]").
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard host == "127.0.0.1" || host == "::1" || host == "localhost" else {
            throw EndpointError.hostNotAllowed(host)
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw EndpointError.unexpectedComponents
        }
        var normalized = components
        normalized.path = ""
        guard let base = normalized.url else {
            throw EndpointError.notAnAbsoluteURL(url.absoluteString)
        }
        self.url = base
    }

    public init(string: String) throws {
        guard let parsed = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme != nil else {
            throw EndpointError.notAnAbsoluteURL(string)
        }
        try self.init(url: parsed)
    }

    public var description: String { url.absoluteString }

    /// `…/v1/models`
    var modelsURL: URL { url.appending(path: "v1").appending(path: "models") }
    /// `…/v1/chat/completions`
    var chatCompletionsURL: URL { url.appending(path: "v1").appending(path: "chat/completions") }
}
