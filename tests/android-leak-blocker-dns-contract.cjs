const fs = require('node:fs');
const assert = require('node:assert/strict');
const sourcePath = process.argv[2] || 'android/app/src/main/java/com/vexguard/app/vpn/VexLeakBlockerService.kt';
const source = fs.readFileSync(sourcePath, 'utf8');
const start = source.indexOf('private fun startBlocking(');
const stop = source.indexOf('private fun stopBlocking(', start);
assert.ok(start >= 0 && stop > start);
const body = source.slice(start, stop);
const configuration = body.slice(body.indexOf('val builder = Builder()'), body.indexOf('if (allowedApplications.isEmpty())'));
const dns = [...configuration.matchAll(/\.addDnsServer\("([^"\n]+)"\)/g)].map((m) => m[1]);
const result = {
  scope: 'source contract only; native/device acceptance is separate',
  explicitDns: dns,
  inheritsUnderlyingDns: dns.length === 0,
  ipv4CatchAll: configuration.includes('.addRoute("0.0.0.0", 0)'),
  ipv6CatchAll: configuration.includes('.addRoute("::", 0)'),
};
console.log(JSON.stringify(result));
if (process.argv[3] !== '--probe') {
  assert.deepEqual(dns, ['10.255.255.2'], 'Blocker must not inherit underlay DNS');
  assert.ok(result.ipv4CatchAll && result.ipv6CatchAll);
  assert.ok(configuration.includes('.setBlocking(false)'));
  assert.ok(body.includes('builder.addDisallowedApplication(packageName)'));
  assert.ok(body.includes('builder.addAllowedApplication(allowedPackage)'));
  assert.doesNotMatch(configuration, /allowBypass|allowFamily/);
  assert.ok(body.includes('input.read(buffer)'));
  assert.ok(!body.includes('output.write'));
  console.log('BLOCKER_FAIL_CLOSED_DNS_CONTRACT=PASS');
}
