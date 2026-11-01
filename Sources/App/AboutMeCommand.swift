import Core
import CryptoKit
import Foundation
import VaultSecurity

/// `UniversalVault --about-me`: the only surface outside the app that reads vault
/// data. It opens the vault with the vault key, builds `AgentProfile`, and prints
/// JSON. It never reads the sensitive key, so protected items cannot be included
/// even by mistake, and it never prompts: a command an agent runs must not block
/// on a biometric dialog.
enum AboutMeCommand {
    enum Failure: Error, LocalizedError {
        case noVault
        case needsMigration
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noVault:
                return "No vault found. Create one in UniversalVault first."
            case .needsMigration:
                return
                    "The vault key still needs a one-time move. Open UniversalVault once, complete the Touch ID prompt, then run this again."
            case .unreadable(let reason):
                return reason
            }
        }
    }

    static func run() -> Int32 {
        do {
            let storage: VaultStorage
            do {
                storage = try FileSystemVaultStorage()
            } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
            guard storage.exists() else { throw Failure.noVault }

            let keyStore = KeychainVaultKeyStore()
            // A legacy key would make the Keychain show a prompt. Refuse instead:
            // an agent's command must be non-interactive.
            if try keyStore.needsOpenKeyMigration() { throw Failure.needsMigration }

            let key: SymmetricKey
            do {
                key = try keyStore.loadKey(reason: "Read the shareable profile")
            } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
            guard let data = try storage.read() else {
                throw Failure.unreadable("The vault file is empty.")
            }
            let payload = try VaultCrypto.decrypt(data, key: key)
            let profile = AgentProfile.build(from: payload)
            FileHandle.standardOutput.write(try profile.jsonData())
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("universalvault --about-me: \(message)\n".utf8))
            return 1
        }
    }
}
