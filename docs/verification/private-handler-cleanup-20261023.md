# Private Windows handler cleanup, 23 October 2026

The private `OnServerModeChecked` method in `HomePage.xaml.cs` had no caller or
XAML event binding. A conservative scan included tracked C#, XAML, project and
build configuration, scripts and documentation; it found only the declaration.
Inspection found no reflection/event registration for it. The method only changed
presentation values for the hidden legacy controls. It is removed.

The remaining source is byte-identical to the preceding file after removing that
single method. XAML and active automatic selection, country cards, location
application, busy-state guards and selection restoration remain unchanged.
Public APIs, route/DNS/firewall behavior and VPN acceptance probes are unchanged.

The full portable client check passes. An independent bounded read-only review
found no introduced defect in the deletion. A macOS host cannot compile or run
the WinUI application; the new exact-head Windows builds remain the runtime/build
qualification gate. This one private method does not establish whole-client or
whole-C# dead-code coverage; dynamic consumers still need individual inspection.

The preceding client head `5d2f1af60d5bf3d26d23439f09384598a7a62c8d` completed
15 successful checks, one encrypted-tunnel failure and one gated signing skip.
The failure was HTTPS control baseline cancellation with parent cancellation
false, operation-budget expiry false and inner timeout true; cleanup was confirmed.
This UI cleanup does not change or fix that failure. TLS validation, operation
limits and the mandatory acceptance evidence remain intact.
