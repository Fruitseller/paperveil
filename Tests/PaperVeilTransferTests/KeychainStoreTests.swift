import Foundation
@testable import PaperVeilTransfer
import Testing

/// Opt-in: run with PAPERVEIL_KEYCHAIN_TEST=1. Avoids touching the user's
/// login keychain in normal test runs.
@Suite struct KeychainStoreTests {
    @Test func setReadUpdateDeleteRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["PAPERVEIL_KEYCHAIN_TEST"] == "1" else {
            return
        }
        let store = KeychainStore(service: "de.paperveil.tests-\(UUID().uuidString.prefix(8))")
        let account = "transfer-key"

        try? store.delete(account: account)  // start clean
        #expect(try store.secret(for: account) == nil)

        try store.set(Data("passphrase-1".utf8), for: account)
        #expect(try store.secret(for: account) == Data("passphrase-1".utf8))

        try store.set(Data("passphrase-2".utf8), for: account)
        #expect(try store.secret(for: account) == Data("passphrase-2".utf8))

        try store.delete(account: account)
        #expect(try store.secret(for: account) == nil)

        // Deleting a missing item is not an error.
        try store.delete(account: account)
    }
}
