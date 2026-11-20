import Foundation
import Testing
@testable import DMCore

@Suite struct EnrollmentTests {
    static let client = "cLiEnT-credential_0123456789abcdefghijklmno"
    static let proof = "pRoOf_secret-0123456789ABCDEFGHIJKLMNOPQRST"
    static let pin = "q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq80="
    static let id = "0b8f6a52-6c1e-4b7e-9a57-0d7a6d2c9f11"

    static func make(
        origin: String = "https://hub.example:8443", id: String = id, client: String = client, proof: String = proof,
        pin: String = pin, name: String = "Matt's iPhone", pairedAt: Date = Date(timeIntervalSince1970: 1_795_000_000.123)
    ) throws -> Enrollment {
        try Enrollment(origin: HubOrigin(origin), id: id, client: client, proof: proof, pin: pin, name: name, pairedAt: pairedAt)
    }

    @Test func fixtureSecretsAreWellFormed() {
        #expect(Self.client.count == 43 && Self.proof.count == 43 && Self.pin.count == 44)
    }

    @Test func roundTripsThroughTheStoredForm() throws {
        let enrollment = try Self.make()
        let data = try KeychainCredentialStore.encode(enrollment)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["v", "origin", "id", "client", "proof", "pin", "name", "pairedAt"])
        #expect(object["v"] as? Int == 1)
        #expect(object["origin"] as? String == "https://hub.example:8443")
        #expect(object["pairedAt"] as? Double == 1_795_000_000_123)
        #expect(try KeychainCredentialStore.decode(data) == enrollment)
        #expect(try JSONDecoder().decode(Enrollment.self, from: JSONEncoder().encode(enrollment)) == enrollment)
        // A non-default date strategy on the encoder must not change the stored form.
        let iso = JSONEncoder()
        iso.dateEncodingStrategy = .iso8601
        #expect(try KeychainCredentialStore.decode(iso.encode(enrollment)) == enrollment)
    }

    @Test func withPinKeepsEverythingElse() throws {
        let enrollment = try Self.make()
        let next = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let rotated = try enrollment.withPin(next)
        #expect(rotated.pin == next)
        #expect(try rotated.withPin(Self.pin) == enrollment)
        #expect(throws: Enrollment.ValidationError.invalidPin) { try enrollment.withPin("nope") }
    }

    @Test func validatesEveryField() throws {
        typealias Invalid = Enrollment.ValidationError
        let a43 = String(repeating: "a", count: 43)
        #expect(throws: Invalid.invalidID) { try Self.make(id: "") }
        #expect(throws: Invalid.invalidID) { try Self.make(id: "-leading") }
        #expect(throws: Invalid.invalidID) { try Self.make(id: "has space") }
        #expect(throws: Invalid.invalidID) { try Self.make(id: "a/b") }
        #expect(throws: Invalid.invalidID) { try Self.make(id: String(repeating: "a", count: 65)) }
        #expect(throws: Invalid.invalidID) { try Self.make(id: "idé") }
        #expect(throws: Invalid.invalidClientCredential) { try Self.make(client: String(repeating: "a", count: 42)) }
        #expect(throws: Invalid.invalidClientCredential) { try Self.make(client: String(repeating: "a", count: 44)) }
        #expect(throws: Invalid.invalidClientCredential) { try Self.make(client: String(repeating: "a", count: 42) + "+") }
        #expect(throws: Invalid.invalidClientCredential) { try Self.make(client: "") }
        #expect(throws: Invalid.invalidProofSecret) { try Self.make(proof: String(repeating: "a", count: 42) + "/") }
        #expect(throws: Invalid.invalidProofSecret) { try Self.make(proof: "") }
        #expect(throws: Invalid.invalidProofSecret) { try Self.make(client: a43, proof: a43) }
        #expect(throws: Invalid.invalidPin) { try Self.make(pin: String(repeating: "A", count: 44)) }
        #expect(throws: Invalid.invalidPin) { try Self.make(pin: String(repeating: "A", count: 42) + "_=") }
        #expect(throws: Invalid.invalidPin) { try Self.make(pin: "") }
        #expect(throws: Invalid.invalidName) { try Self.make(name: "line\nbreak") }
        #expect(throws: Invalid.invalidName) { try Self.make(name: "nul\u{0}") }
        #expect(throws: Invalid.invalidName) { try Self.make(name: String(repeating: "n", count: 121)) }
        #expect(throws: HubError.invalidOrigin) { try Self.make(origin: "http://hub.example") }

        // The hub's own id shapes (isValidId).
        for id in ["a", "A1", "previously-paired-desktop", "aa:bb:cc.dd_ee", String(repeating: "z", count: 64), Self.id] {
            #expect(try Self.make(id: id).id == id)
        }
        #expect(try Self.make(name: "").name == "")
        #expect(try Self.make(name: "Zoë's iPad 📱").name == "Zoë's iPad 📱")
    }

    @Test func decodingAppliesTheSameValidation() throws {
        let good = try #require(try JSONSerialization.jsonObject(with: KeychainCredentialStore.encode(Self.make())) as? [String: Any])
        func decode(_ change: (inout [String: Any]) -> Void) throws -> Enrollment {
            var object = good
            change(&object)
            return try KeychainCredentialStore.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(try decode { _ in } == Self.make())
        let corrupted = CredentialStoreError.corrupted
        #expect(throws: corrupted) { try decode { $0["v"] = 2 } }
        #expect(throws: corrupted) { try decode { $0["v"] = nil } }
        #expect(throws: corrupted) { try decode { $0["origin"] = "http://hub.example:8443" } }
        #expect(throws: corrupted) { try decode { $0["origin"] = "https://hub.example:8443/" } }      // not canonical
        #expect(throws: corrupted) { try decode { $0["origin"] = "https://HUB.example:8443" } }
        #expect(throws: corrupted) { try decode { $0["origin"] = "https://user@hub.example" } }
        #expect(throws: corrupted) { try decode { $0["id"] = "../etc" } }
        #expect(throws: corrupted) { try decode { $0["client"] = "short" } }
        #expect(throws: corrupted) { try decode { $0["client"] = nil } }
        #expect(throws: corrupted) { try decode { $0["proof"] = 7 } }
        #expect(throws: corrupted) { try decode { $0["proof"] = $0["client"] } }
        #expect(throws: corrupted) { try decode { $0["pin"] = Self.client } }
        #expect(throws: corrupted) { try decode { $0["name"] = "bell\u{7}" } }
        #expect(throws: corrupted) { try decode { $0["pairedAt"] = "yesterday" } }
        #expect(throws: corrupted) { try KeychainCredentialStore.decode(Data()) }
        #expect(throws: corrupted) { try KeychainCredentialStore.decode(Data("[]".utf8)) }
        #expect(throws: corrupted) { try KeychainCredentialStore.decode(Data([0xFF, 0x00, 0x30])) }
    }

    /// Nothing that can end up in a log, a crash report or an alert may contain either secret.
    @Test func textNeverContainsSecrets() throws {
        let enrollment = try Self.make()
        var dumped = ""
        dump(enrollment, to: &dumped)
        var dumpedOptional = ""
        dump(Optional(enrollment), to: &dumpedOptional)
        var printed = ""
        print(enrollment, [enrollment], ["e": enrollment], to: &printed)
        var debugPrinted = ""
        debugPrint(enrollment, [enrollment], to: &debugPrinted)
        let texts = [
            enrollment.description, enrollment.debugDescription, "\(enrollment)", String(describing: enrollment),
            String(reflecting: enrollment), dumped, dumpedOptional, printed, debugPrinted,
            String(describing: Mirror(reflecting: enrollment).children.map { "\($0)" }),
            "\(InMemoryCredentialStore(enrollment))",
        ]
        for text in texts {
            #expect(!text.contains(Self.client), "\(text)")
            #expect(!text.contains(Self.proof), "\(text)")
            #expect(!text.contains(String(Self.client.prefix(12))), "\(text)")
            #expect(!text.contains(String(Self.proof.suffix(12))), "\(text)")
        }
        #expect(enrollment.description.contains("https://hub.example:8443"))
        #expect(enrollment.description.contains(Self.id))
        #expect(dumped.contains("redacted"))
    }

    @Test func errorsNeverContainSecrets() throws {
        var errors: [any Error] = [CredentialStoreError.corrupted, CredentialStoreError.keychain(status: -34018)]
        errors += [Enrollment.ValidationError.invalidClientCredential, .invalidProofSecret, .invalidPin, .invalidID, .invalidName, .unsupportedVersion]
        // A stored blob whose client credential is intact but whose pin is damaged: the decoder's
        // own error would quote neighbouring values, so only `.corrupted` may come out.
        var object = try #require(try JSONSerialization.jsonObject(with: KeychainCredentialStore.encode(Self.make())) as? [String: Any])
        object["pin"] = Self.proof
        do {
            _ = try KeychainCredentialStore.decode(JSONSerialization.data(withJSONObject: object))
            Issue.record("a damaged enrollment decoded")
        } catch {
            errors.append(error)
        }
        do {
            _ = try Self.make(client: Self.client + "!", proof: Self.proof)
            Issue.record("an invalid credential was accepted")
        } catch {
            errors.append(error)
        }
        for error in errors {
            let texts = ["\(error)", String(reflecting: error), error.localizedDescription, (error as? any LocalizedError)?.errorDescription ?? ""]
            for text in texts {
                #expect(!text.contains(Self.client) && !text.contains(Self.proof), "\(text)")
                #expect(!text.contains(String(Self.proof.prefix(10))), "\(text)")
            }
        }
        #expect(CredentialStoreError.keychain(status: -34018).errorDescription == "The Keychain is unavailable (error -34018).")
    }

    @Test func cleanNameMatchesTheHub() {
        #expect(Enrollment.cleanName("  Matt's iPhone \n") == "Matt's iPhone")
        #expect(Enrollment.cleanName("a\u{0}b\u{1F}c\u{7F}d") == "abcd")
        #expect(Enrollment.cleanName("\t\n ") == "")
        #expect(Enrollment.cleanName(String(repeating: "x", count: 80)).count == 60)
        // 60 UTF-16 units, without cutting a surrogate pair in half.
        let emoji = Enrollment.cleanName(String(repeating: "😀", count: 40))
        #expect(emoji.utf16.count == 60 && emoji.count == 30)
        #expect(Enrollment.cleanName("x" + String(repeating: "😀", count: 40)).utf16.count == 59)
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.load() == nil)
        let enrollment = try Self.make()
        try store.save(enrollment)
        #expect(try store.load() == enrollment)
        let rotated = try enrollment.withPin("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        try store.save(rotated)
        #expect(try store.load() == rotated)
        try store.clear()
        try store.clear()
        #expect(try store.load() == nil)
        #expect(try InMemoryCredentialStore(enrollment).load() == enrollment)
    }

    @Test func keychainStoreIdentity() {
        #expect(KeychainCredentialStore.defaultService == "com.devicemonitor.ios.enrollment")
    }
}
