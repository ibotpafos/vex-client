#!/usr/bin/env python3
from pathlib import Path
import hashlib, subprocess, sys, tempfile
ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'macos-native/Sources/VEXNativeMac/Services/NativePushPSKEventQueue.swift'
STORE = ROOT / 'macos-native/Sources/VEXNativeMac/Services/NativePushSecureFileStore.swift'
source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
MAIN = r'''import Foundation
@main struct Main {
    static func event(_ id: String) -> NativePushPSKEvent { NativePushPSKEvent(kind: .profile_updated, eventID: id, rotationID: "rotation", deviceID: "device", profileVersion: 1, deadlineAt: nil) }
    static func malformed() -> Bool {
        let base: [String: Any] = ["type": "profile_updated", "event_id": "e", "rotation_id": "r", "device_id": "d"]
        func accepted(_ value: Any) -> Bool { var vex = base; vex["profile_version"] = value; return NativePushPSKEvent.parse(["vex": vex]) != nil }
        let fractional = NativePushPSKEvent.parse(["vex": base.merging(["profile_version": 1, "deadline_at": "2026-10-02T12:34:56.789Z"]) { $1 }]) != nil
        let empty = NativePushPSKEvent.parse(["vex": base.merging(["profile_version": 1, "deadline_at": ""]) { $1 }]) != nil
        return !accepted(true) && !accepted(1.5) && !accepted(Double.infinity) && !accepted(UInt64.max) && !accepted(0) && fractional && empty
    }
    static func mode(_ url: URL) -> Int? { guard let n = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else { return nil }; return n.intValue & 0o777 }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = NativePushPSKEventOwner(accountID: "account", installationID: "installation")!, other = NativePushPSKEventOwner(accountID: "account", installationID: "other")!, queue = NativePushPSKEventQueue(appDataURL: root)
        let first = try queue.enqueue(event("one"), owner: owner), duplicate = try queue.enqueue(event("one"), owner: owner)
        let restart = try NativePushPSKEventQueue(appDataURL: root).events(owner: owner).map(\.eventID) == ["one"], isolated = try queue.events(owner: other).isEmpty
        for value in 0..<40 { _ = try queue.enqueue(event("event-\(value)"), owner: owner) }
        let bounded = try queue.events(owner: owner).count == 32, json = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("push-psk-events"), includingPropertiesForKeys: nil).first!
        let persisted = try String(contentsOf: json, encoding: .utf8); let rawOwnerAbsent = !persisted.contains("account") && !persisted.contains("installation")
        let removed = try queue.remove(eventID: "event-39", owner: owner), removeOnlyOwner = (try queue.events(owner: other)).isEmpty
        try queue.purge(owner: other); let purgeOnlyOwner = !(try queue.events(owner: owner)).isEmpty
        let missingNoop: Bool; do { try FileManager.default.createDirectory(at: root.appendingPathComponent("new-root"), withIntermediateDirectories: true); try NativePushSecureFileStore(rootURL: root.appendingPathComponent("new-root")).remove("x"); missingNoop = true } catch { missingNoop = false }
        let badName: Bool; do { try NativePushSecureFileStore(rootURL: root).write(Data(), name: "../outside"); badName = false } catch { badName = true }
        let permissions = mode(root) == 0o700 && mode(json.deletingLastPathComponent()) == 0o700 && mode(json) == 0o600
        try Data("{}".utf8).write(to: json); let corruptBefore = try Data(contentsOf: json); let corruptRejected: Bool; do { _ = try queue.enqueue(event("after-corrupt"), owner: owner); corruptRejected = false } catch { corruptRejected = true }; let corruptUnchanged = (try Data(contentsOf: json)) == corruptBefore
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); try FileManager.default.removeItem(at: root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("push-psk-events"), withDestinationURL: outside)
        let symlinkRejected: Bool; do { _ = try NativePushPSKEventQueue(appDataURL: root).enqueue(event("symlink"), owner: owner); symlinkRejected = false } catch { symlinkRejected = true }; let outsideUntouched = (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty
        print("source_queue_runtime=true durable_dedupe=\(first && !duplicate && restart) namespace_separation=\(isolated) bounded32=\(bounded)"); print("malformed_metadata_rejected=\(malformed()) corrupt_preserved=\(corruptRejected && corruptUnchanged) symlink_fail_closed=\(symlinkRejected && outsideUntouched) modes_owner_only=\(permissions) raw_owner_absent=\(rawOwnerAbsent) remove_purge_scoped=\(removed && removeOnlyOwner && purgeOnlyOwner) invalid_name_rejected=\(badName) missing_noop=\(missingNoop)")
        exit(first && !duplicate && restart && isolated && bounded && malformed() && corruptRejected && corruptUnchanged && symlinkRejected && outsideUntouched && permissions && rawOwnerAbsent && removed && removeOnlyOwner && purgeOnlyOwner && badName && missingNoop ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vex-native-push-queue-') as directory:
    directory = Path(directory).resolve(); fixture = directory / 'main.swift'; binary = directory / 'probe'; fixture.write_text(MAIN)
    compiled = subprocess.run(['swiftc', str(__import__("pathlib").Path(__file__).resolve().parents[2]/"macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift"),  '-swift-version', '5', '-parse-as-library', str(STORE), str(SOURCE), str(fixture), '-o', str(binary)], text=True, capture_output=True)
    print(compiled.stdout, end=''); print(compiled.stderr, end='', file=sys.stderr)
    if compiled.returncode: raise SystemExit(compiled.returncode)
    app_data = str(directory / 'app-data'); app_data = '/private' + app_data if app_data.startswith('/var/') else app_data
    ran = subprocess.run([str(binary), app_data], text=True, capture_output=True)
    print('source_sha256=' + source_hash); print(ran.stdout, end=''); print(ran.stderr, end='', file=sys.stderr); raise SystemExit(ran.returncode)
