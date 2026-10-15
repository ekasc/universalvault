import Core
import Foundation
import LocalAuthentication

public protocol UserPresenceAuthenticating: Sendable {
    func authenticate(reason: String) async throws -> Bool
}

public enum AuthError: Error, LocalizedError {
    case canceled
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .canceled: return "Authentication canceled."
        case .unavailable: return "Authentication unavailable."
        case .failed(let m): return m
        }
    }
}

public final class LocalAuthenticationService: UserPresenceAuthenticating {
    public init() {}

    public func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw AuthError.unavailable
        }
        return try await withCheckedThrowingContinuation { cont in
            context.evaluatePolicy(policy, localizedReason: reason) { success, err in
                if success {
                    cont.resume(returning: true)
                } else {
                    if let laErr = err as? LAError, laErr.code == .userCancel || laErr.code == .userFallback {
                        cont.resume(throwing: AuthError.canceled)
                    } else {
                        cont.resume(throwing: AuthError.failed(err?.localizedDescription ?? "Authentication failed."))
                    }
                }
            }
        }
    }
}
