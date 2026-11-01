import Foundation
import Testing
@testable import PaperVeilDetection

/// Endpoint validation (loopback-only, http). Pure logic, no server involved.
@Suite struct LMStudioEndpointTests {
    // MARK: Accepted loopback endpoints (SIMULATED input, no network)

    @Test func simulatedLoopbackIPv4Accepted() throws {
        let endpoint = try LMStudioEndpoint(string: "http://127.0.0.1:1234")
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:1234")
    }

    @Test func simulatedLocalhostAccepted() throws {
        let endpoint = try LMStudioEndpoint(string: "http://localhost:1234")
        #expect(endpoint.url.absoluteString == "http://localhost:1234")
    }

    @Test func simulatedLoopbackIPv6Accepted() throws {
        let endpoint = try LMStudioEndpoint(string: "http://[::1]:1234")
        #expect(endpoint.url.absoluteString == "http://[::1]:1234")
    }

    @Test func simulatedTrailingSlashNormalized() throws {
        let endpoint = try LMStudioEndpoint(url: URL(string: "http://127.0.0.1:1234/")!)
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:1234")
    }

    @Test func simulatedLocalDefaultIsLoopback() {
        #expect(LMStudioEndpoint.localDefault.url.absoluteString == "http://127.0.0.1:\(LMStudioEndpoint.defaultPort)")
    }

    // MARK: Rejected endpoints – loopback only, no cloud fallback (D01)

    @Test func simulatedHTTPSRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.schemeNotAllowed("https")) {
            try LMStudioEndpoint(string: "https://127.0.0.1:1234")
        }
    }

    @Test func simulatedMissingSchemeRejected() {
        // "127.0.0.1:1234" is not parsable as a scheme-qualified URL (schemes
        // cannot start with a digit) → rejected with the "provide a full http
        // URL" message.
        #expect(throws: LMStudioEndpoint.EndpointError.self) {
            try LMStudioEndpoint(string: "127.0.0.1:1234")
        }
    }

    @Test func simulatedLANHostRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.hostNotAllowed("192.168.1.5")) {
            try LMStudioEndpoint(string: "http://192.168.1.5:1234")
        }
    }

    @Test func simulatedPublicHostRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.hostNotAllowed("api.openai.com")) {
            try LMStudioEndpoint(string: "http://api.openai.com/v1")
        }
    }

    @Test func simulatedOtherLoopbackRangeRejected() throws {
        // Only the explicit loopback hosts are allowed; 127.0.0.2 is technically
        // loopback but is rejected to keep the allowed set minimal and obvious.
        #expect(throws: LMStudioEndpoint.EndpointError.hostNotAllowed("127.0.0.2")) {
            try LMStudioEndpoint(string: "http://127.0.0.2:1234")
        }
    }

    @Test func simulatedPathRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.unexpectedComponents) {
            try LMStudioEndpoint(string: "http://localhost:1234/v1")
        }
    }

    @Test func simulatedCredentialsRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.unexpectedComponents) {
            try LMStudioEndpoint(string: "http://user:pass@127.0.0.1:1234")
        }
    }

    @Test func simulatedGarbageRejected() {
        #expect(throws: LMStudioEndpoint.EndpointError.self) {
            try LMStudioEndpoint(string: "?? kein host ??")
        }
    }

    @Test func simulatedRejectionMessageIsClear() {
        do {
            _ = try LMStudioEndpoint(string: "http://192.168.1.5:1234")
            Issue.record("Der LAN-Endpunkt hätte abgelehnt werden müssen.")
        } catch let e as LMStudioEndpoint.EndpointError {
            #expect(!e.description.isEmpty)
            #expect(e.description.contains("127.0.0.1"))
        } catch {
            Issue.record("Unerwarteter Fehlertyp: \(type(of: error))")
        }
    }
}
