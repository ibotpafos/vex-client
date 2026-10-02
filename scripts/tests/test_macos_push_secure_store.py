#!/usr/bin/env python3
"""Native macOS secure-store acceptance probe.  This deliberately fails closed."""
from pathlib import Path
import hashlib, subprocess, sys, tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
STORE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushSecureFileStore.swift"
QUEUE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativePushPSKEventQueue.swift"
BEFORE = hashlib.sha256(STORE.read_bytes()).hexdigest()

MAIN = r"""
import Foundation
import Darwin

@main struct Main {
  static func mode(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath:u.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
  static func fail(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
  static func event(_ id:String) -> NativePushPSKEvent { .init(kind:.profile_updated,eventID:id,rotationID:"rotation",deviceID:"device",profileVersion:1,deadlineAt:nil) }
  static func child(_ root:URL) -> URL { root.appendingPathComponent("push-psk-events") }
  static func strictDeadlines() -> Bool {
    let base:[String:Any] = ["type":"profile_updated","event_id":"e","rotation_id":"r","device_id":"d","profile_version":1]
    func parsed(_ deadline:Any) -> Bool { var v=base; v["deadline_at"]=deadline; return NativePushPSKEvent.parse(["vex":v]) != nil }
    return parsed("2026-10-02T12:34:56.789Z") && !parsed(" 2026-10-02T12:34:56Z") && !parsed("not-a-date") && !parsed(1) && !parsed(true)
  }
  static func bytes(_ s:String) -> Data { Data(s.utf8) }
  static func fresh(_ root:URL) throws { try? FileManager.default.removeItem(at:root); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
  static func swapCase(_ base:URL, _ operation:String) throws -> Bool {
    let fm=FileManager.default, root=base.appendingPathComponent("race-\(operation)"), moved=base.appendingPathComponent("moved-\(operation)"), outside=base.appendingPathComponent("outside-\(operation)")
    try fresh(root); try fresh(outside); let marker=outside.appendingPathComponent("marker")
    try bytes("EXTERNAL-MARKER").write(to:marker); _ = try NativePushSecureFileStore(rootURL:root).write(bytes("held"),name:"item")
    var swapped=false
    let hook = { if !swapped { swapped=true; try? fm.removeItem(at:moved); try? fm.moveItem(at:root,to:moved); try? fm.createSymbolicLink(at:root,withDestinationURL:outside) } }
    let store=NativePushSecureFileStore(rootURL:root,afterDirectoryFDOpened:hook)
    let threw:Bool
    if operation == "read" { threw=fail { _ = try store.read("item") } }
    else if operation == "write" { threw=fail { try store.write(bytes("new"),name:"item") } }
    else { threw=fail { try store.remove("item") } }
    let intact=(try Data(contentsOf:marker)) == bytes("EXTERNAL-MARKER") && mode(marker) == 0o644
    return swapped && threw && intact
  }
  static func main() throws {
    let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true); try fresh(base)
    let fm=FileManager.default
    // Names, every symlink position, non-regular/hardlink/mode/size and bounded writes.
    let clean=base.appendingPathComponent("clean"); let store=NativePushSecureFileStore(rootURL:clean,maxBytes:8)
    let names=["../x","a/b",".","..","","a\\b"].allSatisfy { candidate in fail { try store.write(bytes("x"),name:candidate) } }
    let outside=base.appendingPathComponent("outside"); try fresh(outside)
    let components=["ancestor","root","child","leaf","dangling"]
    var links=true
    for kind in components { let r=base.appendingPathComponent("link-\(kind)"); try? fm.removeItem(at:r)
      if kind == "ancestor" { let parent=base.appendingPathComponent("a-parent"); try fresh(parent); try fm.createSymbolicLink(at:parent.appendingPathComponent("link"),withDestinationURL:outside); links = links && fail { try NativePushSecureFileStore(rootURL:parent.appendingPathComponent("link/r")).write(bytes("x"),name:"x") } }
      else if kind == "root" { try fm.createSymbolicLink(at:r,withDestinationURL:outside); links = links && fail { try NativePushSecureFileStore(rootURL:r).write(bytes("x"),name:"x") } }
      else { try fresh(r); let c=child(r); if kind == "child" { try fm.createSymbolicLink(at:c,withDestinationURL:outside) } else { try fm.createDirectory(at:c,withIntermediateDirectories:true); if kind == "leaf" { try fm.createSymbolicLink(at:c.appendingPathComponent("x"),withDestinationURL:outside.appendingPathComponent("x")) } else { try fm.createSymbolicLink(at:c.appendingPathComponent("x"),withDestinationURL:outside.appendingPathComponent("missing")) } }; let s=NativePushSecureFileStore(rootURL:r); links = links && (kind == "child" ? fail { try s.write(bytes("x"),name:"x") } : fail { _ = try s.read("x") }) }
    }
    try store.ensureDirectory(); let dir=child(clean); let regular=dir.appendingPathComponent("regular")
    try bytes("123456789").write(to:regular); let oversize=fail { _=try store.read("regular") }
    try fm.removeItem(at:regular); try bytes("x").write(to:regular); chmod(regular.path,0o644); let broad=fail { _=try store.read("regular") }
    try fm.removeItem(at:regular); try bytes("x").write(to:regular); chmod(regular.path,0o600); try fm.linkItem(at:regular,to:dir.appendingPathComponent("hard")); let hard=fail { _=try store.read("regular") }
    let nonregular=fail { let nonregularURL=dir.appendingPathComponent("nonregular"); try? fm.removeItem(at:nonregularURL); try fm.createDirectory(at:nonregularURL,withIntermediateDirectories:false); _=try store.read("nonregular") }
    let writeCap=fail { try store.write(bytes("123456789"),name:"cap") } && !fm.fileExists(atPath:dir.appendingPathComponent("cap").path)
    // Queue records are opaque namespaces and reject collision/tamper/malformed/duplicates.
    let qroot=base.appendingPathComponent("queue"); let owner=NativePushPSKEventOwner(accountID:"acct",installationID:"install")!, other=NativePushPSKEventOwner(accountID:"acct",installationID:"other")!, q=NativePushPSKEventQueue(appDataURL:qroot)
    _=try q.enqueue(event("one"),owner:owner); let record=try fm.contentsOfDirectory(at:child(qroot),includingPropertiesForKeys:nil).first!; let raw=try String(contentsOf:record); let rawOwnerAbsent = !raw.contains("acct") && !raw.contains("install")
    try bytes("{\"namespace\":\"wrong\",\"events\":[]}").write(to:record); let collision=fail { _=try q.events(owner:owner) }
    try bytes("not-json").write(to:record); let malformed=fail { _=try q.events(owner:owner) }
    let duplicate="{\"namespace\":\"" + String(record.lastPathComponent.dropLast(5)) + "\",\"events\":[{\"kind\":\"profile_updated\",\"eventID\":\"d\",\"rotationID\":\"r\",\"deviceID\":\"x\",\"profileVersion\":1},{\"kind\":\"profile_updated\",\"eventID\":\"d\",\"rotationID\":\"r\",\"deviceID\":\"x\",\"profileVersion\":1}]}"; try bytes(duplicate).write(to:record); chmod(record.path,0o600); let duplicateRejected=fail { _=try q.events(owner:owner) }
    let isolated=(try q.events(owner:other)).isEmpty
    let deadlines=strictDeadlines(); let races=try swapCase(base,"read") && swapCase(base,"write") && swapCase(base,"remove")
    let ok=names && links && oversize && broad && hard && nonregular && writeCap && rawOwnerAbsent && collision && malformed && duplicateRejected && isolated && deadlines && races
    print("secure_store_acceptance names=\(names) symlinks=\(links) oversize=\(oversize) broad=\(broad) hard=\(hard) nonregular=\(nonregular) writecap=\(writeCap)")
    print("queue namespace=\(rawOwnerAbsent && collision) malformed=\(malformed) duplicate=\(duplicateRejected) owner_isolated=\(isolated) strict_deadlines=\(deadlines) mapping_race_fail_closed=\(races)")
    exit(ok ? 0 : 1)
  }
}
"""
with tempfile.TemporaryDirectory(prefix="vex-secure-store-") as td:
    td=Path(td).resolve(); fixture=td/"main.swift"; binary=td/"probe"; fixture.write_text(MAIN)
    compiled=subprocess.run(["swiftc", str(__import__("pathlib").Path(__file__).resolve().parents[2]/"macos-native/Sources/VEXNativeMac/Services/NativePSKIdentifier.swift"), "-swift-version","5","-parse-as-library",str(STORE),str(QUEUE),str(fixture),"-o",str(binary)],text=True,capture_output=True)
    print(compiled.stdout,end=""); print(compiled.stderr,end="",file=sys.stderr)
    if compiled.returncode: raise SystemExit(compiled.returncode)
    root=str(td/"root"); root="/private"+root if root.startswith("/var/") else root
    ran=subprocess.run([str(binary),root],text=True,capture_output=True)
    print("source_sha256_before="+BEFORE); print("source_sha256_after="+hashlib.sha256(STORE.read_bytes()).hexdigest()); print(ran.stdout,end=""); print(ran.stderr,end="",file=sys.stderr); raise SystemExit(ran.returncode)
