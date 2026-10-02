#!/usr/bin/env python3
"""Compile actual HelperCore with in-memory files/fake pfctl; never run real PF."""
from pathlib import Path
import os, subprocess, tempfile, sys
ROOT=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(__file__).resolve().parents[2]
CORE=ROOT/"macos-native/Sources/VEXHelperCore"
SUPPORTED="func updateWhileArmed(endpoint: String, interfaceName: String) throws" in (CORE/"SystemSupport.swift").read_text()
HARNESS=r'''
import Foundation
final class Files:HelperFileSystem,@unchecked Sendable {
 var data:[String:String];var mutations:[String]=[];var failPath:String?;var failCount=0
 init(_ d:[String:String]){data=d}
 func createDirectory(at p:String)throws{mutations.append("mkdir:"+p)}
 func fileExists(at p:String)->Bool{data[p] != nil}
 func fileSize(at p:String)->UInt64?{data[p].map{UInt64($0.utf8.count)}}
 func modificationDate(at p:String)->Date?{nil}
 func readText(at p:String)throws->String{guard let v=data[p] else{throw HelperError.io("missing fixture")};return v}
 func writeTextAtomically(_ t:String,to p:String,mode:Int)throws{mutations.append("write:"+p);if failPath==p && failCount>0{failCount-=1;throw HelperError.io("injected atomic write")};data[p]=t}
 func removeItem(at p:String)throws{mutations.append("remove:"+p);data.removeValue(forKey:p)}
}
// Only a fake output renderer: actual admission/rollback policy is in HelperCore.
func displayed(_ anchor:String)->String{
 anchor.split(separator:"\n").filter{!$0.hasPrefix("set ")}.map{line in
  var s=String(line)
  if s.hasPrefix("pass"),!s.contains(" proto udp "){
   if s.hasSuffix(" keep state"){s.removeLast(" keep state".count)}
   s += " flags S/SA keep state"
  }
  return s.replacingOccurrences(of:"port = 443",with:"port = https").replacingOccurrences(of:"port = 22",with:"port = ssh")
 }.joined(separator:"\n")+"\n"
}
final class Runner:CommandRunning,@unchecked Sendable{
 var calls:[CommandSpec]=[];var info="Status: Enabled for 0 days 00:10:00\n";var loadResults:[Int32]=[]
 var runtime:String;var loaded:[String]=[];var corruptFirstLoad=false;weak var files:Files?
 init(_ f:Files){files=f;runtime=displayed(f.data["/f/anchor"]!)}
 func run(_ s:CommandSpec)throws->CommandResult{
  calls.append(s);guard s.program=="/sbin/pfctl" else{throw HelperError.commandFailed("unexpected fake executable")}
  if s.arguments==["-s","info"]{return .init(status:0,stdout:info)}
  if s.arguments==["-a","com.vexguard.antileak","-sr"]{return .init(status:0,stdout:runtime)}
  if s.arguments==["-a","com.vexguard.antileak","-f","/f/anchor"]{
   let status=loadResults.isEmpty ? 0:loadResults.removeFirst()
   let rules=files!.data["/f/anchor"]!;loaded.append(rules)
   if status==0{runtime=displayed(rules);if corruptFirstLoad && loaded.count==1{runtime="pass out quick on en0 all\n"+runtime}}
   return .init(status:status)
  }
  throw HelperError.commandFailed("unexpected fake PF command")
 }
}
func fixture()->(SystemPFFirewallController,Files,Runner){
 let p=HelperPathsLayout(helperDirectory:"/f",antileakStatePath:"/f/state",legacyAntileakStatePath:"/f/legacy",antileakAnchorPath:"/f/anchor",pfConfigPath:"/f/pf")
 let f=Files(["/f/anchor":"set block-policy drop\npass quick on lo0 all\npass out quick on utun7 all\npass out quick inet proto udp from any to 198.51.100.7 port = 51820 keep state\npass out quick inet proto tcp from any to 198.51.100.7 port = 443 keep state\npass out quick inet proto tcp from any to 198.51.100.7 port = 22 keep state\nblock drop out all\n","/f/state":"status=active\nendpoint=198.51.100.7:51820\niface=utun7\n","/f/legacy":"legacy original\n","/f/pf":"anchor \"com.vexguard.antileak\"\nload anchor \"com.vexguard.antileak\" from \"/f/anchor\"\n"])
 let r=Runner(f);return(SystemPFFirewallController(runner:r,fileSystem:f,paths:p),f,r)
}
func require(_ b:Bool,_ l:String){if !b{fputs("PF assertion: \(l)\n",stderr);exit(1)}}
func noDanger(_ r:Runner)->Bool{r.calls.allSatisfy{$0.arguments==["-s","info"] || $0.arguments==["-a","com.vexguard.antileak","-sr"] || $0.arguments==["-a","com.vexguard.antileak","-f","/f/anchor"]}}
func fail(_ c:SystemPFFirewallController,endpoint:String="198.51.100.8:51820",interface:String="utun7")->String{
 do{try c.updateWhileArmed(endpoint:endpoint,interfaceName:interface);return "unexpected success"}catch{return error.localizedDescription}
}
ABSENT_EXTENSION
if !SUPPORTED{let(c,_,r)=fixture();_=fail(c);print("pf_armed_replacement supported=false loads=\(r.loaded.count)");exit(1)}
do{
 let(c,f,r)=fixture();try c.updateWhileArmed(endpoint:"198.51.100.8:51820",interfaceName:"utun7")
 require(r.loaded.count==1 && r.runtime==displayed(f.data["/f/anchor"]!),"success actual loaded file")
 require(f.data["/f/state"]=="status=active\nendpoint=198.51.100.8:51820\niface=utun7\n" && f.data["/f/legacy"]==nil && noDanger(r),"success state/commands")
}
for kind in ["load","verify-after-load","state-once","anchor-once"]{
 let(c,f,r)=fixture();let original=f.data;let beforeRuntime=r.runtime
 if kind=="load"{r.loadResults=[1,0]}
 if kind=="verify-after-load"{r.corruptFirstLoad=true}
 if kind=="state-once"{f.failPath="/f/state";f.failCount=1}
 if kind=="anchor-once"{f.failPath="/f/anchor";f.failCount=1}
 require(fail(c) != "unexpected success","failure injected "+kind)
 require(f.data==original && r.runtime==beforeRuntime && noDanger(r),"exact files/runtime restore "+kind)
 require(r.loaded.last==original["/f/anchor"],"rollback source file load "+kind)
 if kind != "anchor-once"{require(r.loaded.count==2,"candidate then rollback "+kind)}
 print("pf_failure case=\(kind) restored_files=true restored_runtime=true anchor_loads=\(r.loaded.count) forbidden_commands=0")
}
for kind in ["disabled","unknown-status","duplicate-status","physical-interface","bad-endpoint","missing-udp-port","commented-registration","source-file-mismatch","source-state-duplicate","runtime-extra-pass","runtime-missing-rule","runtime-wrong-port","runtime-wrong-af","runtime-reordered"]{
 let(c,f,r)=fixture();var endpoint="198.51.100.8:51820",interface="utun7"
 switch kind{
 case "disabled":r.info="Status: Disabled\n"
 case "unknown-status":r.info="Status: Unknown\n"
 case "duplicate-status":r.info="Status: Enabled\nStatus: Disabled\n"
 case "physical-interface":interface="en0"
 case "bad-endpoint":endpoint="bad;block all"
 case "missing-udp-port":endpoint="198.51.100.8"
 case "commented-registration":f.data["/f/pf"]="#anchor \"com.vexguard.antileak\"\n#load anchor \"com.vexguard.antileak\" from \"/f/anchor\"\n"
 case "source-file-mismatch":f.data["/f/anchor"]! += "pass out quick on en0 all\n"
 case "source-state-duplicate":f.data["/f/state"]! += "iface=utun7\n"
 case "runtime-extra-pass":r.runtime="pass out quick on en0 all\n"+r.runtime
 case "runtime-missing-rule":r.runtime=r.runtime.split(separator:"\n").filter{!$0.contains("port = ssh")}.joined(separator:"\n")+"\n"
 case "runtime-wrong-port":r.runtime=r.runtime.replacingOccurrences(of:"51820",with:"51821")
 case "runtime-wrong-af":r.runtime=r.runtime.replacingOccurrences(of:"inet proto udp",with:"inet6 proto udp")
 case "runtime-reordered":r.runtime=r.runtime.split(separator:"\n").reversed().joined(separator:"\n")+"\n"
 default:break
 }
 let before=f.data;require(fail(c,endpoint:endpoint,interface:interface) != "unexpected success","guard "+kind)
 require(f.data==before && f.mutations.isEmpty && r.loaded.isEmpty && noDanger(r),"no mutation guard "+kind)
}
for kind in ["rollback-load","rollback-metadata"]{
 let(c,f,r)=fixture();let before=f.data
 if kind=="rollback-load"{r.loadResults=[1,2]}else{f.failPath="/f/state";f.failCount=2}
 require(fail(c).contains("rollback failed"),"explicit rollback failure "+kind)
 require(noDanger(r) && f.data["/f/anchor"]==before["/f/anchor"] && f.data["/f/legacy"]==before["/f/legacy"],"no open/flush despite rollback failure")
}
print("pf_armed_replacement supported=true canonical_exact=true success=true load_rollback=true verify_after_load_rollback=true persistence_rollback=true guards=14 rollback_failure=true forbidden_commands=0")
'''
fallback='' if SUPPORTED else 'extension SystemPFFirewallController { func updateWhileArmed(endpoint:String,interfaceName:String)throws { throw HelperError.commandFailed("unsupported baseline capability") } }'
swift=HARNESS.replace('ABSENT_EXTENSION',fallback).replace('SUPPORTED','true' if SUPPORTED else 'false')
scratch=Path("/Volumes/D/Projects/mobile/.vex-tmp");scratch.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='pf-fake-',dir=scratch) as tmp:
 d=Path(tmp);(d/'main.swift').write_text(swift)
 build=subprocess.run(['rtk','proxy','swiftc','-swift-version','5',*map(str,sorted(CORE.glob('*.swift'))),str(d/'main.swift'),'-framework','Security','-framework','SystemConfiguration','-lbsm','-o',str(d/'probe')])
 if build.returncode:raise SystemExit(build.returncode)
 raise SystemExit(subprocess.run(['rtk','proxy',str(d/'probe')]).returncode)
