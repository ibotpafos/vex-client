import Darwin
import XCTest
@testable import VEXNativeMac

final class HelperSocketSimulationTests: XCTestCase {
    func testResponseFrameRequiresNewlineAndValidUTF8() throws {
        XCTAssertEqual(
            try decodeHelperResponseFrame(Array("ok\n".utf8), reachedLimit: false),
            "ok\n"
        )
        XCTAssertThrowsError(
            try decodeHelperResponseFrame(Array("ok".utf8), reachedLimit: false)
        )
        XCTAssertThrowsError(
            try decodeHelperResponseFrame([0xFF, 0x0A], reachedLimit: false)
        )
        XCTAssertThrowsError(
            try decodeHelperResponseFrame(Array("partial".utf8), reachedLimit: true)
        )
    }

    func testClientSocketSuppressesSIGPIPE() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }

        configureHelperClientSocket(sockets[0], timeoutSeconds: 1)

        var noSIGPIPE: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, &length),
            0
        )
        XCTAssertEqual(noSIGPIPE, 1)
    }

    func testShutdownCommandCompletesAgainstSimulatedHelper() async throws {
        let server = try SimulatedHelperSocket { command in
            command == "shutdown" ? "ok\n" : "error: unexpected command\n"
        }
        defer { server.stop() }

        let client = VEXHelperClient(socketPath: server.path)
        try await client.sendExpectingOK("shutdown", timeoutSeconds: 1)

        XCTAssertEqual(server.waitForCommand(), "shutdown")
    }

    func testTextualHelperErrorIsNotAcceptedAsSuccessfulShutdown() async {
        let server = try! SimulatedHelperSocket { _ in "error: pf cleanup failed\n" }
        defer { server.stop() }

        do {
            try await VEXHelperClient(socketPath: server.path)
                .sendExpectingOK("shutdown", timeoutSeconds: 1)
            XCTFail("A textual helper error must fail the operation")
        } catch let error as VEXHelperError {
            guard case .commandFailed(let response) = error else {
                return XCTFail("Unexpected helper error: \(error)")
            }
            XCTAssertTrue(response.contains("pf cleanup failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnresponsiveSimulatedHelperCannotHangQuitIndefinitely() async {
        let server = try! SimulatedHelperSocket(responseDelay: 2) { _ in nil }
        defer { server.stop() }
        let started = ContinuousClock.now

        do {
            _ = try await VEXHelperClient(socketPath: server.path)
                .send("shutdown", timeoutSeconds: 1)
            XCTFail("An unresponsive helper must time out")
        } catch {
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        }
    }
}

private final class SimulatedHelperSocket: @unchecked Sendable {
    let path: String

    private let listener: Int32
    private let responseDelay: UInt32
    private let response: @Sendable (String) -> String?
    private let worker = DispatchGroup()
    private let lock = NSLock()
    private var receivedCommand: String?

    init(
        responseDelay: UInt32 = 0,
        response: @escaping @Sendable (String) -> String?
    ) throws {
        path = "/tmp/vex-helper-\(UUID().uuidString.prefix(8)).sock"
        self.responseDelay = responseDelay
        self.response = response
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    maxPathLength
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        worker.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { worker.leave() }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }

            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1 {
                if byte == 10 { break }
                bytes.append(byte)
            }
            let command = String(decoding: bytes, as: UTF8.self)
            lock.lock()
            receivedCommand = command
            lock.unlock()

            if responseDelay > 0 {
                sleep(responseDelay)
            }
            guard let payload = response(command) else { return }
            payload.withCString { pointer in
                _ = Darwin.write(client, pointer, strlen(pointer))
            }
        }
    }

    func waitForCommand() -> String? {
        _ = worker.wait(timeout: .now() + 2)
        lock.lock()
        defer { lock.unlock() }
        return receivedCommand
    }

    func stop() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = worker.wait(timeout: .now() + 3)
        unlink(path)
    }
}
