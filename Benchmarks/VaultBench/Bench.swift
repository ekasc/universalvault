import Foundation
import Core
import VaultSecurity
import CryptoKit

/// Measures the operations on the interactive path: opening the vault, one
/// keystroke of search, and one autosaved edit. Numbers here are the app's own
/// code, not a proxy.
@main
struct VaultBench {
    @MainActor
    static func main() async throws {
        var arguments = CommandLine.arguments.dropFirst()
        var itemCount = 500
        var fieldsPerItem = 8
        var runs = 5
        while let argument = arguments.popFirst() {
            switch argument {
            case "--items": itemCount = Int(arguments.popFirst() ?? "") ?? itemCount
            case "--fields": fieldsPerItem = Int(arguments.popFirst() ?? "") ?? fieldsPerItem
            case "--runs": runs = Int(arguments.popFirst() ?? "") ?? runs
            default: break
            }
        }
        let payload = syntheticPayload(items: itemCount, fieldsPerItem: fieldsPerItem)
        let fieldCount = payload.items.reduce(0) { $0 + $1.fields.count }
        print("vault: \(payload.items.count) items, \(fieldCount) fields, runs=\(runs)")

        let key = SymmetricKey(size: .bits256)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try! encoder.encode(payload)
        let encrypted = try! VaultCrypto.encrypt(payload: payload, key: key)

        print(String(format: "payload size: %.1f KiB plaintext, %.1f KiB encrypted",
                     Double(plaintext.count) / 1024, Double(encrypted.count) / 1024))

        report("json encode", runs: runs) { _ = try encoder.encode(payload) }
        report("json decode", runs: runs) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(VaultPayload.self, from: plaintext)
        }
        report("validate payload", runs: runs) { _ = try payload.validated() }
        report("encrypt", runs: runs) { _ = try VaultCrypto.encrypt(payload: payload, key: key) }
        report("decrypt + validate", runs: runs) { _ = try VaultCrypto.decrypt(encrypted, key: key) }

        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultBench-io-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let benchStorage = try! FileSystemVaultStorage(directory: storageDirectory)
        try! benchStorage.write(encrypted)
        report("storage read (1.7 MiB)", runs: runs) { _ = try benchStorage.read() }
        report("storage CAS write (1.7 MiB)", runs: runs) {
            try benchStorage.write(encrypted, expected: encrypted)
        }

        let engine = SearchEngine()
        report("search: empty query", runs: runs) { _ = engine.search(query: "", payload: payload) }
        report("search: \"e\"", runs: runs) { _ = engine.search(query: "e", payload: payload) }
        report("search: no match", runs: runs) { _ = engine.search(query: "zzzzzz", payload: payload) }
        let index = SearchIndex(payload: payload)
        assert(index.search(query: "e").count == engine.search(query: "e", payload: payload).count)
        assert(index.search(query: "").count == engine.search(query: "", payload: payload).count)
        report("index build", runs: runs) { _ = SearchIndex(payload: payload) }
        report("index search: empty query", runs: runs) { _ = index.search(query: "") }
        report("index search: \"e\"", runs: runs) { _ = index.search(query: "e") }
        report("index search: no match", runs: runs) { _ = index.search(query: "zzzzzz") }
        report("browser filter: \"e\"", runs: runs) {
            _ = VaultBrowser.items(payload.items, selection: .allItems, search: "e")
        }
        report("agent profile", runs: runs) { _ = AgentProfile.build(from: payload) }

        await reportMainThreadBlock("open: main-thread block", runs: runs) { session in
            try await session.unlock()
        }
        await reportAsync("session open (file -> payload)", runs: runs) {
            let (session, store, directory) = try makeSession(payload: payload, key: key)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = store
            try await session.unlock()
        }
        // One session for the save measurements: opening the vault is already
        // measured above and would otherwise be counted inside every save.
        let (saveSession, _, saveDirectory) = try makeSession(payload: payload, key: key)
        try await saveSession.unlock()
        await reportMainThreadBlock("legacy save on main (old path)", runs: runs) { _ in
            var legacy = payload
            legacy.updatedAt = Date()
            _ = try legacy.validated()
            let data = try VaultCrypto.encrypt(payload: legacy, key: key)
            try benchStorage.write(data)
        }
        await reportMainThreadBlock("save: main-thread block", runs: runs) { session in
            try await session.unlock()
            try await session.mutate(actionName: "Bench edit") { payload in
                guard var item = payload.items.first, var field = item.fields.first else { return }
                field.value = .text(UUID().uuidString)
                item.fields[0] = field
                payload.items[0] = item
            }
        }
        await reportAsync("autosave: one field edit", runs: runs) {
            try await saveSession.mutate(actionName: "Bench edit") { payload in
                guard var item = payload.items.first, var field = item.fields.first else { return }
                field.value = .text(UUID().uuidString)
                item.fields[0] = field
                payload.items[0] = item
            }
        }
        try? FileManager.default.removeItem(at: saveDirectory)
    }

    // MARK: - Harness

    private static func report(_ name: String, runs: Int, _ body: () throws -> Void) {
        var samples: [Double] = []
        do {
            try body()  // warm up
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                try body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        } catch {
            print("\(pad(name, 34)) FAILED \(error.localizedDescription)")
            return
        }
        print(line(name, samples))
    }

    /// Measures the longest stretch the main actor went without servicing a 1 ms
    /// ticker while the operation ran. This is what a keystroke actually feels:
    /// total work matters less than whether it happens on the main thread.
    @MainActor
    private static func reportMainThreadBlock(
        _ name: String, runs: Int, _ body: @MainActor (VaultSession) async throws -> Void
    ) async {
        var samples: [Double] = []
        for _ in 0..<runs {
            guard let (session, _, directory) = try? makeSession(
                payload: syntheticPayload(items: 500, fieldsPerItem: 8),
                key: SymmetricKey(size: .bits256))
            else { return }
            defer { try? FileManager.default.removeItem(at: directory) }
            var lastTick = DispatchTime.now().uptimeNanoseconds
            var longestGap: Double = 0
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    let now = DispatchTime.now().uptimeNanoseconds
                    longestGap = max(longestGap, Double(now - lastTick) / 1_000_000)
                    lastTick = now
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            // Let the ticker establish its cadence before the operation starts.
            try? await Task.sleep(for: .milliseconds(10))
            lastTick = DispatchTime.now().uptimeNanoseconds
            longestGap = 0
            do { try await body(session) } catch { return }
            // Give the ticker one wake-up to record the stretch the body held the
            // main actor, including the synchronous case where it could not run.
            try? await Task.sleep(for: .milliseconds(5))
            ticker.cancel()
            await ticker.value
            samples.append(longestGap)
        }
        print(line(name, samples))
    }

    @MainActor
    private static func reportAsync(_ name: String, runs: Int, _ body: () async throws -> Void) async {
        var samples: [Double] = []
        do {
            try await body()
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                try await body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        } catch {
            print("\(pad(name, 34)) FAILED \(error.localizedDescription)")
            return
        }
        print(line(name, samples))
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func line(_ name: String, _ samples: [Double]) -> String {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let best = sorted.first ?? 0
        return "\(pad(name, 34)) median \(String(format: "%7.2f", median)) ms   best \(String(format: "%7.2f", best)) ms"
    }

    // MARK: - Fixtures

    private static func syntheticPayload(items: Int, fieldsPerItem: Int) -> VaultPayload {
        var payload = VaultPayload()
        payload.categories = (0..<8).map { VaultCategory(name: "Category \($0)", sortOrder: $0) }
        payload.profiles = (0..<4).map { Profile(name: "Profile \($0)", sortOrder: $0) }
        payload.items = (0..<items).map { index in
            let fields = (0..<fieldsPerItem).map { fieldIndex in
                VaultField(
                    key: "field\(fieldIndex)",
                    label: fieldIndex == 0 ? "Name" : "Field \(fieldIndex)",
                    type: .text,
                    value: .text("Value \(index)-\(fieldIndex) lorem ipsum dolor sit amet"),
                    sensitivity: fieldIndex % 7 == 0 ? .sensitive : .normal,
                    aliases: fieldIndex == 1 ? ["alias\(index)"] : [],
                    sortOrder: fieldIndex)
            }
            return VaultItem(
                title: "Item \(index) alpha beta",
                categoryID: payload.categories[index % payload.categories.count].id,
                profileID: payload.profiles[index % payload.profiles.count].id,
                tags: ["tag\(index % 5)", "common"],
                fields: fields,
                sortOrder: index)
        }
        return payload
    }

    @MainActor
    private static func makeSession(
        payload: VaultPayload, key: SymmetricKey
    ) throws -> (VaultSession, BenchKeyStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultBench-\(UUID().uuidString)", isDirectory: true)
        let storage = try FileSystemVaultStorage(directory: directory)
        try storage.write(try VaultCrypto.encrypt(payload: payload, key: key))
        let store = BenchKeyStore(key: key)
        let session = VaultSession(storage: storage, keyStore: store, auth: BenchAuth())
        return (session, store, directory)
    }
}

private final class BenchKeyStore: VaultKeyStore, @unchecked Sendable {
    private let key: SymmetricKey
    private var sensitive: SymmetricKey?
    init(key: SymmetricKey) { self.key = key }
    func keyExists() throws -> Bool { true }
    func loadKey(reason: String) throws -> SymmetricKey { key }
    func storeKey(_ key: SymmetricKey) throws {}
    func deleteKey() throws {}
    func sensitiveKeyExists() throws -> Bool { sensitive != nil }
    func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
        guard let sensitive else { throw KeyStoreError.notFound }
        return sensitive
    }
    func storeSensitiveKey(_ key: SymmetricKey) throws { sensitive = key }
    func deleteSensitiveKey() throws { sensitive = nil }
}

private struct BenchAuth: UserPresenceAuthenticating {
    func authenticate(reason: String) async throws -> Bool { true }
}
