#!/usr/bin/env python3
"""Compile real grouping code and the current VpnLocation declaration without XCTest."""
from pathlib import Path
import subprocess,tempfile
R=Path(__file__).resolve().parents[2]
models=R/'macos-native/Sources/VEXNativeMac/Models'
s=(models/'VEXModels.swift').read_text(); location=s[s.index('struct VpnLocation:'):s.index('struct AppUpdateCheckResult:')]
presentation=(models/'FocusPulsePresentation.swift').read_text()
formatters=presentation[presentation.index('    static func nodeCountText'):presentation.index('    static func featuredLocations')]
harness=r'''
func loc(_ id:String,_ code:String,_ healthy:Int=1,_ ping:Double?=10,_ state:String="healthy") -> VpnLocation {
 VpnLocation(id:id,countryCode:code,city:id,flagEmoji:nil,availability:"available",status:state,healthyNodes:healthy,latencyMs:ping)
}
let de=loc("de","DE"), feature=loc("de-awg31-features"," de ",1,7), fi=loc("fi","FI")
let groups=VEXCountryGroup.make([de,feature,fi],selectedID:feature.id)
precondition(groups.count==2 && groups[0].availableNodeCount==2)
precondition(groups[0].representative.id==feature.id && groups[0].isSelected)
precondition(groups[0].locations.count==2 && groups[0].cardLocation.healthyNodes==2)
precondition(feature.healthyNodes==1 && de.id=="de")
precondition(VEXCountryGroup.make([de,de,feature],selectedID:"")[0].availableNodeCount==2)
let offline=loc("de-offline","DE",5,1,"maintenance")
let selectedOffline=VEXCountryGroup.make([de,offline],selectedID:offline.id)[0]
precondition(selectedOffline.availableNodeCount==1 && selectedOffline.representative.id==offline.id)
precondition(selectedOffline.cardLocation.latencyMs==nil)
precondition(VEXCountryGroup.make([offline],selectedID:"")[0].availableNodeCount==0)
precondition(VEXCountryGroup.make([loc("x",""),loc("y","")],selectedID:"").count==2)
precondition(VEXCountryGroup.make([loc("x","--"),loc("y","--")],selectedID:"").count==2)
precondition(VEXCountryGroup.make([],selectedID:"").isEmpty)
precondition(VEXCountryGroup.make([de],selectedID:"",limit:0).isEmpty)
let many=(0..<8).map{loc("de\($0)","DE")}+[fi]
let limited=VEXCountryGroup.make(many,selectedID:"fi",limit:2)
precondition(limited.count==2 && limited[1].locations.count==8)
let nan=loc("nan","DE",1,Double.nan)
precondition(VEXCountryGroup.make([nan,de],selectedID:"")[0].representative.id=="de")
precondition(VEXCountryGroup.make([feature,de],selectedID:"",limit:1)[0].representative.id==feature.id)
precondition(Formatting.nodeCountText(1)=="1 узел")
precondition(Formatting.nodeCountText(2)=="2 узла")
precondition(Formatting.nodeCountText(5)=="5 узлов")
precondition(Formatting.nodeCountText(11)=="11 узлов")
precondition(Formatting.nodeCountText(21)=="21 узел")
precondition(Formatting.nodeCountText(22)=="22 узла")
precondition(Formatting.latencyText(Double.nan)==nil)
precondition(Formatting.latencyText(Double.infinity)==nil)
precondition(Formatting.latencyText(-1)==nil)
precondition(Formatting.latencyText(7.6)=="8 мс")
print("PASS: Russian node plurals and invalid/rounded ping")
print("PASS: country grouping, normalization, counts, selected/offline retention, duplicates, unknowns, empty/limit, missing/NaN ping, original IDs")
'''
with tempfile.TemporaryDirectory(prefix='vex-country-test-') as d:
 p=Path(d);(p/'main.swift').write_text('import Foundation\n'+location+'\nenum Formatting {\n'+formatters+'\n}\n'+harness)
 subprocess.run(['swiftc',str(models/'VEXCountryGroup.swift'),str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
home=(R/'macos-native/Sources/VEXNativeMac/Views/HomePanel.swift').read_text()
assert 'return appState.locations' in home and 'ForEach(countries)' in home
assert 'action: { expandedCountryID = country.id }' in home
assert 'onSelect(location)' in home
print('PASS: home groups before limit; card opens chooser; explicit node selection retains original ID')
