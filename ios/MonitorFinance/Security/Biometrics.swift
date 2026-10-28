import Foundation
import LocalAuthentication

enum Biometrics {
    /// False on the simulator unless Face ID is enrolled, and always false under `-noBiometrics`.
    static var isAvailable: Bool {
        if Launch.noBiometrics { return false }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        guard isAvailable else { return false }
        let context = LAContext()
        context.localizedCancelTitle = "Ввести код"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }
}
