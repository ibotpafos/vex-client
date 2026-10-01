#!/usr/bin/env python3
"""Compile the real macOS safety policy sources and verify fail-closed wiring."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos-native/Sources/VEXNativeMac"

def section(text, start, end):
    return text[text.index(start):text.index(end)]

models = (MAC / "Models/VEXModels.swift").read_text()
location = section(models, "struct VpnLocation:", "struct AppUpdateCheckResult:")
helper = (MAC / "VEXHelperClient.swift").read_text()
state = section(helper, "enum VpnConnectionState:", "    var title:") + "}\n"
updater = (MAC / "Services/SparkleUpdaterService.swift").read_text()
policy = section(updater, "struct NativeVPNUpdateSafetySnapshot:", "enum SparkleUpdaterConfiguration")
selection = (MAC / "Models/VpnLocationSelection.swift").read_text()
removal = (MAC / "Models/DeviceRemovalSafety.swift").read_text()
harness = r'''
func loc(_ id:String, _ availability:String="available", _ status:String="healthy", _ healthy:Int=1, _ awg3:Int?=1, _ latency:Double?=10) -> VpnLocation { VpnLocation(id:id,countryCode:"DE",city:id,flagEmoji:nil,availability:availability,status:status,healthyNodes:healthy,awg3Nodes:awg3,latencyMs:latency) }
let good=loc("good","available","healthy",1,1,12), hidden=loc("hidden","hidden","healthy",1,1,1), maintenance=loc("maintenance","maintenance","healthy",1,1,2), unhealthy=loc("unhealthy","available","healthy",0,1,3), awg2=loc("awg2","available","healthy",1,0,4)
precondition(VpnLocationSelection.targetID(locations:[hidden,maintenance,unhealthy,awg2,good],selectedID:"stale",automatic:true)=="good")
precondition(VpnLocationSelection.targetID(locations:[good],selectedID:"",automatic:false)==nil)
precondition(VpnLocationSelection.targetID(locations:[good],selectedID:"stale",automatic:false)==nil)
let nan=loc("nan","available","healthy",1,1,.nan), neg=loc("neg","available","healthy",1,1,-1), b=loc("b","available","healthy",1,1,5), a=loc("a","available","healthy",1,1,5)
precondition(VpnLocationSelection.targetID(locations:[nan,neg,b,a],selectedID:"",automatic:true)=="a")
precondition(VpnLocationSelection.fallback(locations:[loc("DE"),maintenance,loc("nl","available","healthy",1,1,7)],excluding:" de ")?.id=="nl")
precondition(!DeviceRemovalSafety.permitsRemoval(confirmedIdle:false,helperBusy:false,vpnBusy:false,activeDeviceID:nil,requestedDeviceID:"d"))
precondition(!DeviceRemovalSafety.permitsRemoval(confirmedIdle:true,helperBusy:false,vpnBusy:false,activeDeviceID:"d",requestedDeviceID:"d"))
precondition(DeviceRemovalSafety.permitsRemoval(confirmedIdle:true,helperBusy:false,vpnBusy:false,activeDeviceID:"d",requestedDeviceID:"other"))
precondition(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(nil))
for state in [VpnConnectionState.connected,.connecting,.disconnecting] { precondition(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(helperState:state,hasManagedNetworkState:true,helperIsBusy:false,hasActiveTunnelRoute:false))) }
precondition(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(helperState:.disconnected,hasManagedNetworkState:true,helperIsBusy:false,hasActiveTunnelRoute:false)))
precondition(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(helperState:.disconnected,hasManagedNetworkState:false,helperIsBusy:true,hasActiveTunnelRoute:false)))
precondition(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(helperState:.disconnected,hasManagedNetworkState:false,helperIsBusy:false,hasActiveTunnelRoute:true)))
precondition(!NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(helperState:.disconnected,hasManagedNetworkState:false,helperIsBusy:false,hasActiveTunnelRoute:false)))
for interface in ["utun0","tun12","tap3","ppp4","ipsec5"," IPSEC6 "] { precondition(NativeVPNUpdateSafetyPolicy.hasKnownTunnelInterface(interface)) }
for interface in ["","en0","bridge0","utun","utunx","tap-1","ipsec0x"] { precondition(!NativeVPNUpdateSafetyPolicy.hasKnownTunnelInterface(interface)) }
print("PASS: real release safety policy")
'''
with tempfile.TemporaryDirectory() as d:
    source = Path(d) / "main.swift"
    source.write_text("import Foundation\n" + location + "\n" + state + "\n" + policy + "\n" + selection + "\n" + removal + "\n" + harness)
    out = Path(d) / "probe"
    subprocess.run(["swiftc", str(source), "-o", str(out)], check=True)
    subprocess.run([str(out)], check=True)

api = (MAC / "Services/VEXAPIClient.swift").read_text()
app = (MAC / "Stores/VEXAppState.swift").read_text()
account = (MAC / "Views/AccountPanel.swift").read_text()
shell = (MAC / "VEXNativeMacApp.swift").read_text()
assert "return locations.filter(\\.isSelectable)" in api
assert "VpnLocationSelection.targetID(" in app and "VpnLocationSelection.fallback(" in app
assert "await helper.refreshStatus(quiet: true)" in app and "guard canRemoveDevice(device, using: helper) else" in app
assert ".disabled(!appState.canRemoveDevice(device, using: helper))" in account
assert "hasConfirmedIdleStatus = false" in helper
assert "guard let helper, helper.hasConfirmedIdleStatus else { return nil }" in shell
assert "NativeVPNUpdateSafetyPolicy.hasKnownTunnelInterface(status.routeInterface)" in shell
assert "shouldPostponeRelaunchForUpdate" in updater and "NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(" in updater
print("PASS: production wiring is fail-closed")
