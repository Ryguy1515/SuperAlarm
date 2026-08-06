import Foundation
import LocalAuthentication

/// The Face ID mission. Biometric matching is used deliberately without a
/// passcode fallback: Face ID with attention detection needs your eyes open
/// and your face square to the phone, which is exactly the proof of wakefulness
/// the mission is after.
public enum BiometricMission {
    public enum Outcome: Equatable {
        case success
        case failed(String)
        case unavailable(String)
        case cancelled
    }

    public static var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    public static var displayName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    public static var symbolName: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.shield"
        }
    }

    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Describes why biometrics cannot be used, if they cannot.
    public static var unavailableReason: String? {
        var error: NSError?
        let context = LAContext()
        guard !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        guard let code = error.map({ LAError.Code(rawValue: $0.code) }) ?? nil else {
            return "Biometrics are not available on this device."
        }
        switch code {
        case .biometryNotEnrolled:
            return "No face or fingerprint is enrolled. Set one up in Settings, or pick a different mission."
        case .biometryNotAvailable:
            return "This device has no biometric sensor, or access was denied."
        case .biometryLockout:
            return "Biometrics are locked out after too many failed attempts. Unlock your phone once, then try again."
        default:
            return "Biometrics are unavailable right now."
        }
    }

    public static func authenticate(reason: String = "Confirm it's really you and turn off the alarm") async -> Outcome {
        let context = LAContext()
        context.localizedFallbackTitle = ""

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable(unavailableReason ?? "Biometrics are unavailable.")
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success ? .success : .failed("Not recognised. Try again.")
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .biometryLockout:
                return .unavailable(
                    "Biometrics are locked out. Unlock your phone with your passcode once, then try again."
                )
            case .biometryNotEnrolled, .biometryNotAvailable:
                return .unavailable(unavailableReason ?? "Biometrics are unavailable.")
            default:
                return .failed("Not recognised. Try again.")
            }
        } catch {
            return .failed("Not recognised. Try again.")
        }
    }
}
