import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/**
 * APPLE'S APP ATTEST (`DCAppAttestService`, iOS 14+; the SDK's floor is 15),
 * behind `AppAttesting` so the proof's logic runs — and is tested — without
 * it. Only an iPhone, iPad, Mac Catalyst or visionOS app proves itself: a Mac
 * runs the tests alone, and a simulator answers `isSupported == false` (it
 * uses its debug token, §3.6).
 *
 * The app adds the App Attest capability (Xcode → the target → Signing &
 * Capabilities → + Capability → App Attest). Its entitlement says
 * `development` for builds Xcode installs and `production` for TestFlight and
 * the App Store — Apple uses production for every distributed build.
 */
enum AppAttestDevice {
    /// App Attest on this device, or nil where there is none to ask.
    static func make() -> AppAttesting? {
        #if canImport(DeviceCheck) && (os(iOS) || os(visionOS))
        return DeviceCheckAttest()
        #else
        return nil
        #endif
    }
}

#if canImport(DeviceCheck)
@available(iOS 14.0, macOS 11.0, macCatalyst 14.0, tvOS 15.0, watchOS 9.0, *)
final class DeviceCheckAttest: AppAttesting {
    private var service: DCAppAttestService { DCAppAttestService.shared }

    var isSupported: Bool { service.isSupported }

    func generateKey(_ done: @escaping (Result<String, AppAttestFailure>) -> Void) {
        service.generateKey { keyId, error in
            if let id = keyId, !id.isEmpty, error == nil { return done(.success(id)) }
            done(.failure(Self.failure(error)))
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void) {
        service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
            if let object = attestation, error == nil { return done(.success(object)) }
            done(.failure(Self.failure(error)))
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void) {
        service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
            if let object = assertion, error == nil { return done(.success(object)) }
            done(.failure(Self.failure(error)))
        }
    }

    /// `DCError` as the proof reads it: a key that is gone, Apple out of reach, a device that cannot.
    static func failure(_ error: Error?) -> AppAttestFailure {
        guard let error = error else { return .failed("App Attest answered nothing") }
        let ns = error as NSError
        guard ns.domain == DCErrorDomain, let code = DCError.Code(rawValue: ns.code) else {
            return .failed(ns.localizedDescription)
        }
        switch code {
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .serverUnavailable
        case .featureUnsupported: return .unsupported
        default: return .failed(ns.localizedDescription)
        }
    }
}
#endif
