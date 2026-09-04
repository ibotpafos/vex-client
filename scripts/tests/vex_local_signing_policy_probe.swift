import Darwin
import Foundation
import Security

// Compile alongside PeerAuthenticator.swift; no XCTest/Xcode dependency.
@main
struct SigningPolicyProbe {
    static func main() {
        var requirement: SecRequirement?
        precondition(SecRequirementCreateWithString(SystemPeerAuthenticator.clientRequirement as CFString, [], &requirement) == errSecSuccess)
        guard let requirement else { fatalError("requirement missing") }
        if CommandLine.arguments.count == 3 {
            let path = CommandLine.arguments[1]
            let expected = CommandLine.arguments[2] == "accept"
            var code: SecStaticCode?
            let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
            let result = code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) } ?? created
            print("static=\(result == errSecSuccess ? "accept" : "reject") status=\(result)")
            precondition((result == errSecSuccess) == expected)
        } else {
            var token = audit_token_t()
            var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &token) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
                }
            }
            precondition(status == KERN_SUCCESS)
            let credentials = PeerCredentials(pid: getpid(), auditToken: Data(bytes: &token, count: MemoryLayout.size(ofValue: token)), effectiveUID: geteuid())
            let accepted = SystemPeerAuthenticator().authenticate(credentials)
            print("live-audit-token=\(accepted ? "accept" : "reject") uid=\(geteuid())")
            precondition(!SystemPeerAuthenticator().authenticate(PeerCredentials(pid: getpid(), auditToken: Data(), effectiveUID: uid_t.max)))
            if let expected = ProcessInfo.processInfo.environment["PROBE_EXPECT"] {
                precondition(accepted == (expected == "accept"))
            }
        }
    }
}
