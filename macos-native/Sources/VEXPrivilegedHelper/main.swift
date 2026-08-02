import Darwin
import Foundation
import VEXHelperCore

@main
enum VEXPrivilegedHelperMain {
    static func main() async {
        guard geteuid() == 0 else {
            fputs("VEXPrivilegedHelper must run as root\n", stderr)
            exit(77)
        }

        signal(SIGPIPE, SIG_IGN)

        let paths = HelperPathsLayout()
        let runtime = HelperRuntime.makeDefault()

        do {
            try await runtime.bootstrap()
            try UnixSocketServer(socketPath: paths.socketPath).run(runtime: runtime)
        } catch {
            fputs("VEXPrivilegedHelper failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
