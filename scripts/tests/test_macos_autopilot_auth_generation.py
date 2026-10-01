#!/usr/bin/env python3
"""Runtime-only fake test for exact VpnAdmissionRecovery retry behavior."""
from pathlib import Path
import subprocess,tempfile,sys
ROOT=Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]; src=(ROOT/'macos-native/Sources/VEXNativeMac/Services/VpnAdmissionRecovery.swift').read_text()
a=src.index('    static func retryFreshProfile<T>(')
# The default predicate is itself a closure, so find the body only after the
# declaration's parentheses close rather than taking that closure's opening brace.
paren=0; b=a
while True:
 ch=src[b]
 if ch=='(': paren+=1
 elif ch==')': paren-=1
 elif ch=='{' and paren==0: break
 b+=1
d=1; e=b+1
while d: d+=(src[e]=='{')-(src[e]=='}'); e+=1
method=src[a:e]
new_api='shouldFailover:' in method
adapter='' if new_api else '''
// BASELINE-COMPAT ADAPTER: forwards to the exact legacy body and deliberately
// drops only the new predicate label; it does not reproduce catch logic.
static func retryFreshProfile<T>(shouldFailover: (Error)->Bool, attempt: () async throws -> T, failover: (Error) async throws -> T) async throws -> T { try await retryFreshProfile(attempt: attempt, failover: failover) }
'''
h='''import Foundation
enum AuthenticatedOperationError: Error { case sessionChanged }; struct Generic: Error {}
struct Config: LocalizedError { var errorDescription:String? { "VPN_CONFIG_INVALID" } }
@MainActor enum VpnAdmissionRecovery {'''+method+adapter+'''}
@main struct Probe { @MainActor static func main() async {
 func count(_ error:Error, predicate:@escaping(Error)->Bool) async -> Int { var n=0; do { let _:Int = try await VpnAdmissionRecovery.retryFreshProfile(shouldFailover: predicate, attempt:{throw error}, failover:{_ in n+=1;return 1}) } catch {}; return n }
 let safe: (Error) -> Bool = { !($0 is AuthenticatedOperationError) && !($0 is CancellationError) }
 let stale=await count(AuthenticatedOperationError.sessionChanged,predicate:safe); let cancel=await count(CancellationError(),predicate:safe); let config=await count(Config(),predicate:safe); let transient=await count(Generic(),predicate:safe)
 var defaultFailover=0; let _:Int?=try? await VpnAdmissionRecovery.retryFreshProfile(attempt:{throw Generic()},failover:{_ in defaultFailover+=1;return 1})
 let normal:Int=try! await VpnAdmissionRecovery.retryFreshProfile(attempt:{7},failover:{_ in 8})
 print("baseline_adapter=\\(!'''+str(new_api).lower()+''')"); print("stale_failovers=\\(stale)"); print("cancel_failovers=\\(cancel)"); print("config_failovers=\\(config)"); print("transient_failovers=\\(transient)"); print("default_failovers=\\(defaultFailover)"); print("normal_path=\\(normal==7)")
 exit(stale==0 && cancel==0 && config==0 && transient==1 && defaultFailover==1 && normal==7 ? 0:1)
} }\n'''
with tempfile.TemporaryDirectory(prefix='vex-autopilot-auth-') as d:
 p=Path(d);(p/'main.swift').write_text(h); c=subprocess.run(['swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'p')],capture_output=True,text=True)
 if c.returncode: raise SystemExit(f'swiftc exit={c.returncode}\nstdout:\n{c.stdout}\nstderr:\n{c.stderr}')
 raise SystemExit(subprocess.run([str(p/'p')]).returncode)
