import XCTest
import Core

/// The agent-facing document is the one place vault data leaves the app, so these
/// tests pin the filter rather than the formatting.
final class AgentProfileTests: XCTestCase {
    private func item(
        _ title: String,
        share: Bool = true,
        sensitive: Bool = false,
        fields: [VaultField]
    ) -> VaultItem {
        VaultItem(title: title, fields: fields, isSensitive: sensitive, isShareableWithAgents: share)
    }

    func testOnlyMarkedItemsAreShared() throws {
        let payload = VaultPayload(items: [
            item("About me", fields: [VaultField(key: "name", label: "Name", value: .text("Ekas"))]),
            item("Unmarked", share: false, fields: [
                VaultField(key: "city", label: "City", value: .text("Pune"))
            ]),
        ])
        let profile = AgentProfile.build(from: payload)
        XCTAssertEqual(profile.items.map(\.title), ["About me"])
        XCTAssertEqual(profile.items.first?.fields, [AgentProfile.Field(label: "Name", value: "Ekas")])
    }

    func testProtectedItemsAreNeverSharedEvenWhenMarked() throws {
        let payload = VaultPayload(items: [
            item("Bank", sensitive: true, fields: [
                VaultField(key: "pin", label: "PIN", value: .text("1234"))
            ])
        ])
        let profile = AgentProfile.build(from: payload)
        XCTAssertTrue(profile.items.isEmpty)
    }

    func testSensitiveAndSecretFieldsAreDropped() throws {
        let payload = VaultPayload(items: [
            item("Profile", fields: [
                VaultField(key: "name", label: "Name", value: .text("Ekas")),
                VaultField(key: "email", label: "Email", value: .email("e@example.com")),
                VaultField(
                    key: "api", label: "API key", value: .text("sk-live-123"),
                    sensitivity: .sensitive),
                VaultField(
                    key: "ssn", label: "SSN", value: .text("000-00-0000"),
                    sensitivity: .critical),
                VaultField(
                    key: "token", label: "Token", value: .secret("s3cret"), sensitivity: .sensitive),
            ])
        ])
        let profile = AgentProfile.build(from: payload)
        let labels = profile.items.first?.fields.map(\.label) ?? []
        XCTAssertEqual(labels, ["Name", "Email"])
        let json = try XCTUnwrap(
            String(data: try profile.jsonData(), encoding: .utf8))
        XCTAssertFalse(json.contains("sk-live-123"))
        XCTAssertFalse(json.contains("000-00-0000"))
        XCTAssertFalse(json.contains("s3cret"))
    }

    /// A secret-typed field is forced to sensitive by validation, but the builder
    /// must not rely on that having run.
    func testSecretTypeIsExcludedEvenAtNormalSensitivity() throws {
        let payload = VaultPayload(items: [
            item("Profile", fields: [
                VaultField(key: "token", label: "Token", type: .secret, value: .secret("abc"))
            ])
        ])
        XCTAssertTrue(AgentProfile.build(from: payload).items.isEmpty)
    }

    func testItemsWithNothingShareableAreOmitted() throws {
        let payload = VaultPayload(items: [
            item("Only secrets", fields: [
                VaultField(
                    key: "api", label: "API key", value: .text("sk-live-123"),
                    sensitivity: .critical)
            ])
        ])
        XCTAssertTrue(AgentProfile.build(from: payload).items.isEmpty)
    }

    func testDocumentShapeIsStable() throws {
        let payload = VaultPayload(items: [
            item("About me", fields: [VaultField(key: "name", label: "Name", value: .text("Ekas"))])
        ])
        let data = try AgentProfile.build(from: payload).jsonData()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "universalvault.about-me")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["generatedAt"])
        XCTAssertNotNil(object["vaultUpdatedAt"])
        XCTAssertNotNil(object["items"])
    }

    /// A payload written before agent sharing existed decodes with sharing off.
    func testLegacyItemDefaultsToNotShared() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old","tags":[],"fields":[],\
        "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","sortOrder":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VaultItem.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.isShareableWithAgents)
    }
}
