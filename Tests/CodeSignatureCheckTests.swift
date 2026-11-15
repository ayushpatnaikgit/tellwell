import Foundation
import Security

/// The updater installs a download only if it satisfies the running app's designated requirement. These checks use
/// Apple-signed system tools as fixtures: a matching requirement passes; another identity, a non-Apple anchor or a
/// missing file fails.
enum CodeSignatureCheckTests {
    static func run() {
        let ls = URL(fileURLWithPath: "/bin/ls")
        TestSupport.expect(isSuccess(CodeSignatureCheck.verify(ls, satisfies: requirement(#"identifier "com.apple.ls" and anchor apple"#))),
                           "an Apple-signed tool satisfies its own requirement")
        TestSupport.expect(!isSuccess(CodeSignatureCheck.verify(ls, satisfies: requirement(#"identifier "io.github.ayushpatnaikgit.tellwell""#))),
                           "a different bundle identifier must fail")
        TestSupport.expect(!isSuccess(CodeSignatureCheck.verify(ls, satisfies: requirement(#"identifier "com.apple.ls" and certificate leaf = H"0000000000000000000000000000000000000000""#))),
                           "a different signing certificate must fail")
        let missing = URL(fileURLWithPath: "/nonexistent/TellWell.app")
        TestSupport.expect(!isSuccess(CodeSignatureCheck.verify(missing, satisfies: requirement("anchor apple"))),
                           "a missing bundle must fail")
        // The test runner is built ad-hoc signed: it has no developer identity to trust, so updates are refused.
        TestSupport.expect({ if case .failure(.runningAppUnsigned) = CodeSignatureCheck.verifyMatchesRunningApp(ls) { return true }; return false }(),
                           "an ad-hoc signed build must refuse to self-update")
    }

    private static func isSuccess(_ result: Result<Void, CodeSignatureCheck.Failure>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func requirement(_ text: String) -> SecRequirement {
        var req: SecRequirement?
        precondition(SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil, text)
        return req!
    }
}
