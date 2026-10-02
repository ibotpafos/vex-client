#!/usr/bin/env python3
"""Actual private state reader/writer on a disposable directory; no network ports."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
strict = "public func readPrivateText(" in (CORE / "SystemSupport.swift").read_text()
HARNESS = r'''
import Foundation
import Darwin
let root=CommandLine.arguments[1]
precondition(root.hasPrefix("/private/") || root.hasPrefix("/Volumes/"))
let fs=LocalFileSystem(),fm=FileManager.default
func read(_ path:String,_ limit:Int=16384)throws->String {
 #if PRIVATE_RECEIPT_READER
 return try fs.readPrivateText(at:path,maxBytes:limit)
 #else
 // Execute the old production disk-read semantics, not a pretend strict reader.
 return try fs.readText(at:path)
 #endif
}
func denied(_ body:()throws->Void)->Bool {do {try body();return false}catch{return true}}
var cases=0,failures=0
func check(_ name:String,_ pass:Bool) {cases+=1;if !pass {failures+=1};print("private_receipt_file \(name)=\(pass ? "PASS" : "FAIL")")}
let path=root+"/receipt.state",fixture="receipt-fixture\n"
try fs.writeTextAtomically(fixture,to:path,mode:0o600)
var info=stat();precondition(lstat(path,&info)==0)
check("atomic-write-owner-only-roundtrip",try read(path)==fixture && info.st_mode & 0o777 == 0o600)
check("bounded-read",denied{_=try read(path,2)})
check("zero-bound",denied{_=try read(path,0)})
check("excessive-bound",denied{_=try read(path,1048577)})
let broad=root+"/broad";try fs.writeTextAtomically(fixture,to:broad,mode:0o644)
check("broad-permissions",denied{_=try read(broad)})
let linked=root+"/linked";try fm.linkItem(atPath:path,toPath:linked)
check("hard-link",denied{_=try read(path)})
try fm.removeItem(atPath:linked)
let symlink=root+"/symlink";try fm.createSymbolicLink(atPath:symlink,withDestinationPath:path)
check("leaf-symlink",denied{_=try read(symlink)})
let directory=root+"/nested";try fm.createDirectory(atPath:directory,withIntermediateDirectories:false)
try fs.writeTextAtomically(fixture,to:directory+"/receipt",mode:0o600)
try fm.createSymbolicLink(atPath:root+"/alias",withDestinationPath:directory)
check("ancestor-symlink",denied{_=try read(root+"/alias/receipt")})
check("directory-not-file",denied{_=try read(directory)})
check("traversal-dotdot",denied{_=try read(root+"/nested/../receipt.state")})
check("nul-path",denied{_=try read(path+"\0ignored")})
let invalid=root+"/invalid";try Data([0xff,0xfe]).write(to:URL(fileURLWithPath:invalid));precondition(chmod(invalid,0o600)==0)
check("invalid-UTF8",denied{_=try read(invalid)})
check("valid-reopened-after-errors",try read(path)==fixture)
print("private_receipt_file_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
exit(failures==0 ? 0 : 1)
'''
scratch = Path(os.environ.get("TMPDIR", "/private/tmp")).resolve()
with tempfile.TemporaryDirectory(prefix="private-receipt-", dir=scratch) as raw:
    directory = Path(raw).resolve()
    (directory / "main.swift").write_text(HARNESS)
    subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5",
                    *(["-D", "PRIVATE_RECEIPT_READER"] if strict else []),
                    *map(str, sorted(CORE.glob("*.swift"))), str(directory / "main.swift"),
                    "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm",
                    "-o", str(directory / "probe")], check=True, timeout=180)
    data = directory / "data"
    data.mkdir(mode=0o700)
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe"), str(data)], timeout=60).returncode)
