import Foundation
import Security

/// Checks that a downloaded app was signed by the same developer as the running app before the updater installs it.
///
/// The running app's designated requirement (its bundle identifier and signing certificate) must be satisfied by the
/// new bundle, with every file and nested binary intact. A tampered download, or one signed by anyone else, fails.
enum CodeSignatureCheck {
    enum Failure: Error, Equatable {
        /// This build has no stable signature to compare against (an ad-hoc or unsigned development build).
        case runningAppUnsigned
        case invalidSignature(OSStatus)

        var message: String {
            switch self {
            case .runningAppUnsigned:
                return "This copy of the app is not signed, so updates can't be verified. Download the new version from the website instead."
            case .invalidSignature:
                return "The downloaded update is not signed by the developer of this app, so it was not installed."
            }
        }
    }

    /// The running app's designated requirement, or nil if it has none worth trusting (ad-hoc signed).
    static func runningAppRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        // Ad-hoc signatures have no certificate; their requirement is just a hash of this exact build.
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32, flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Whether the bundle at `url` is validly signed and satisfies `requirement`.
    static func verify(_ url: URL, satisfies requirement: SecRequirement) -> Result<Void, Failure> {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else { return .failure(.invalidSignature(created)) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        return status == errSecSuccess ? .success(()) : .failure(.invalidSignature(status))
    }

    /// Whether the bundle at `url` was signed by the same developer as the running app.
    static func verifyMatchesRunningApp(_ url: URL) -> Result<Void, Failure> {
        guard let requirement = runningAppRequirement() else { return .failure(.runningAppUnsigned) }
        return verify(url, satisfies: requirement)
    }
}
