#!/usr/bin/env python3
"""Compile real loadBilling against a gated fake backend; no HTTP/UI/helper."""
from pathlib import Path
import subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT / "macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift"
text = source.read_text()
start = text.index("    private func loadBilling(_ token: String) async {")
end = text.index("    private func loadRemoteConfig()", start)
method = text[start:end].replace("    private func", "    func", 1)
harness = r'''
import Foundation
struct User: Equatable { let id: String }
struct AuthSession: Equatable { let user: User; let accessToken: String }
struct BillingPlan: Equatable { let id: String }
struct Entitlement: Equatable { let id: String }
struct BillingSummary: Equatable { let id: String }
struct BillingPayment: Equatable { let id: String }
struct DeviceAddon: Equatable { let id: String }
struct VpnDevice: Equatable { let id: String }
enum FixtureError: LocalizedError { case failed; var errorDescription: String? { "fixture failure" } }
enum VEXAPIError: Error { case forbidden; var isForbidden: Bool { self == .forbidden } }
@MainActor final class Cache { var saved:[(String,BillingSummary)] = []; func load(userId:String)->BillingSummary? { nil }; func save(userId:String,summary:BillingSummary){saved.append((userId,summary))} }
@MainActor final class Billing { func buildSummary(plans:[BillingPlan],entitlement:Entitlement?)->BillingSummary { .init(id:"summary-"+(entitlement?.id ?? "none")+"-"+String(plans.count)) } }
@MainActor final class API {
 var result:Result<Entitlement,Error> = .success(.init(id:"entitlement")); var hold=false
 private var started:CheckedContinuation<Void,Never>?; private var resume:CheckedContinuation<Void,Never>?
 func billingPlans() async throws -> [BillingPlan] { [.init(id:"plan")] }
 func entitlement(accessToken:String) async throws -> Entitlement { if hold { await withCheckedContinuation { c in resume=c; started?.resume(); started=nil } }; return try result.get() }
 func billingPayments(accessToken:String,limit:Int) async throws -> [BillingPayment] { [.init(id:"payment")] }
 func billingDeviceAddons(accessToken:String) async throws -> [DeviceAddon] { [.init(id:"addon")] }
 func vpnDevices(accessToken:String) async throws -> [VpnDevice] { [.init(id:"device")] }
 func waitStart() async { if resume != nil{return}; await withCheckedContinuation { started=$0 } }
 func release(){resume?.resume();resume=nil}
}
@MainActor final class H {
 var session:AuthSession?; var user:User?; var authenticatedSessionGeneration=0
 var billingSummary:BillingSummary?; var entitlement:Entitlement?; var billingPayments:[BillingPayment]=[]; var deviceAddons:[DeviceAddon]=[]; var accountDevices:[VpnDevice]=[]; var deviceManagementRequiresWeb=true; var billingError:String?; var statusMessage:String?; var diagnostics=0
 let api=API(); let billingSummaryCache=Cache(); let billingService=Billing()
 func submitDiagnostics(reason:String,status:String,samples:[String:String]) async { diagnostics += 1 }
'''
tail = r'''
}
@main struct Main {
 static func make() async -> H { await MainActor.run { let h=H(); h.session = .init(user: .init(id: "account"), accessToken: "same-token"); h.user = .init(id: "account"); return h } }
 static func none(_ h:H) async { await MainActor.run { precondition(h.entitlement==nil,"late entitlement"); precondition(h.billingSummary==nil,"late summary"); precondition(h.billingSummaryCache.saved.isEmpty,"late cache"); precondition(h.billingPayments.isEmpty,"late payments"); precondition(h.deviceAddons.isEmpty,"late addons"); precondition(h.accountDevices.isEmpty,"late devices"); precondition(h.billingError==nil && h.statusMessage==nil && h.diagnostics==0,"late error") } }
 static func main() async {
  let ok=await make(); await MainActor.run{ok.api.hold=true}; let pending=Task{await ok.loadBilling("same-token")}; await ok.api.waitStart(); await MainActor.run{ok.authenticatedSessionGeneration += 1; ok.api.release()}; _=await pending.value; await none(ok)
  let bad=await make(); await MainActor.run{bad.api.hold=true;bad.api.result = .failure(FixtureError.failed)}; let failing=Task{await bad.loadBilling("same-token")}; await bad.api.waitStart(); await MainActor.run{bad.authenticatedSessionGeneration += 1;bad.api.release()}; _=await failing.value; await none(bad)
  let current=await make(); await current.loadBilling("same-token"); await MainActor.run { precondition(current.entitlement == .init(id: "entitlement")); precondition(current.billingSummary == .init(id: "summary-entitlement-1")); precondition(current.billingSummaryCache.saved.count == 1 && current.billingSummaryCache.saved[0].0 == "account" && current.billingSummaryCache.saved[0].1 == .init(id: "summary-entitlement-1")); precondition(current.billingPayments == [.init(id: "payment")]); precondition(current.deviceAddons == [.init(id: "addon")]); precondition(current.accountDevices == [.init(id: "device")]); precondition(!current.deviceManagementRequiresWeb); precondition(current.billingError==nil && current.statusMessage==nil && current.diagnostics==0) }
  print("PASS: loadBilling rejects same-token stale success/error writes and accepts current fixtures")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="vex-billing-generation-") as d:
 main=Path(d)/"main.swift"; main.write_text(harness+method+tail); exe=Path(d)/"probe"
 subprocess.run(["swiftc","-swift-version","5","-parse-as-library",str(main),"-o",str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
