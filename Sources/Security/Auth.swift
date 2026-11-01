import Core
import Foundation
import LocalAuthentication
import Synchronization

/// An `LAContext` that has already satisfied a presence check, wrapped so it
/// can cross isolation. Reusing it for a Keychain read satisfies user-presence
/// access control without a second prompt.
public final class AuthenticatedContext: @unchecked Sendable {
  public let context: LAContext

  init(_ context: LAContext) {
    self.context = context
  }
}

private final class AuthenticationContext: Sendable {
  let value = Mutex(LAContext())
}

public protocol UserPresenceAuthenticating: Sendable {
  func authenticate(reason: String) async throws -> Bool
  /// The context from the most recent successful authentication, if any.
  func authenticatedContext() -> AuthenticatedContext?
  /// Discards cached presence so it cannot authorize a later read.
  func invalidateAuthentication()
}

public extension UserPresenceAuthenticating {
  func authenticatedContext() -> AuthenticatedContext? { nil }
  func invalidateAuthentication() {}
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
  private let lastContext = Mutex<AuthenticatedContext?>(nil)

  public init() {}

  public func authenticate(reason: String) async throws -> Bool {
    let context = AuthenticationContext()
    var error: NSError?
    let policy = LAPolicy.deviceOwnerAuthentication
    guard context.value.withLock({ $0.canEvaluatePolicy(policy, error: &error) }) else {
      throw AuthError.unavailable
    }
    let success = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { cont in
        context.value.withLock { context in
          context.evaluatePolicy(policy, localizedReason: reason) { success, err in
            if success {
              cont.resume(returning: true)
            } else {
              if let laErr = err as? LAError,
                laErr.code == .userCancel || laErr.code == .userFallback
              {
                cont.resume(throwing: AuthError.canceled)
              } else {
                cont.resume(
                  throwing: AuthError.failed(err?.localizedDescription ?? "Authentication failed."))
              }
            }
          }
        }
      }
    } onCancel: {
      context.value.withLock { $0.invalidate() }
    }
    if success {
      let authenticated = AuthenticatedContext(context.value.withLock { $0 })
      lastContext.withLock { $0 = authenticated }
    }
    return success
  }

  public func authenticatedContext() -> AuthenticatedContext? {
    lastContext.withLock { $0 }
  }

  public func invalidateAuthentication() {
    lastContext.withLock { stored in
      stored?.context.invalidate()
      stored = nil
    }
  }
}
