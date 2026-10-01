#!/usr/bin/env python3
"""Compile real SSE metadata plus foreground-notice policy; no sockets/UI/helper."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos-native/Sources/VEXNativeMac"
wire = (MAC / "Services/CustomerRealtimeService.swift").read_text().split("@MainActor\nfinal class CustomerRealtimeService", 1)[0]
policy = (MAC / "Models/CustomerNotificationPolicy.swift").read_text()
service = (MAC / "Services/CustomerNotificationService.swift").read_text()
assert "UNUserNotificationCenterDelegate" in service
assert "center.delegate = self" in service
assert "completionHandler([.banner, .list, .sound])" in service
harness = r'''
var policy = CustomerNotificationPolicy()
func notices(_ type: String, _ id: String, _ data: String) -> [CustomerNotificationPayload] {
    let event = CustomerRealtimeEvent(type: type, id: id, data: data)
    guard let metadata = CustomerRealtimeMetadata.parse(type: type, data: data) else { return [] }
    return policy.consume(event: event, metadata: metadata)
}
precondition(notices("customer.heartbeat", "h1", "{}").isEmpty)
precondition(notices("customer.session.revoked", "r1", "{\"reason\":\"session_invalid\"}").isEmpty)
precondition(notices("customer.resync", "sync", "{\"versions\":[{\"domain\":\"support\"}],\"reason\":\"resync\"}").isEmpty)
precondition(notices("customer.change", "", "{\"domain\":\"support\",\"version\":1}").isEmpty)
precondition(notices("customer.change", "x", "{\"domain\":\"unknown\",\"version\":1}").isEmpty)
precondition(notices("customer.change", "b", "{\"domain\":\"billing\",\"version\":1}").isEmpty)
let support = notices("customer.change", "s1", "{\"domain\":\"support\",\"version\":1,\"secret\":\"DO_NOT_DISPLAY\"}")
precondition(support.count == 1 && support[0].domain == "support")
precondition(!support[0].body.contains("DO_NOT_DISPLAY"))
precondition(notices("customer.change", "s1", "{\"domain\":\"support\",\"version\":1}").isEmpty)
precondition(notices("customer.change", "release1", "{\"domain\":\"releases\",\"version\":1}").count == 1)
policy.reset()
precondition(notices("customer.change", "s1", "{\"domain\":\"support\",\"version\":1}").count == 1)
print("PASS: foreground-only SSE notices are deduplicated and privacy-reduced; APNs/unread counts not claimed")
'''
with tempfile.TemporaryDirectory(prefix="vex-notification-policy-") as directory:
    source = Path(directory) / "main.swift"
    source.write_text(wire + "\n" + policy + "\n" + harness)
    executable = Path(directory) / "probe"
    subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", str(source), "-o", str(executable)], check=True)
    subprocess.run(["rtk", "proxy", str(executable)], check=True)
