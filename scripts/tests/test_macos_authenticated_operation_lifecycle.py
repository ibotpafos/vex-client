#!/usr/bin/env python3
"""Compile and execute extracted authenticated-operation bodies with fake gates only."""
from pathlib import Path
import os, subprocess, sys, tempfile
SOURCE_REL=Path('macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift')
def body(s,m):
 a=s.index(m); b=s.index('{',a); n=1; e=b+1
 while n:
  n += (s[e]=='{')-(s[e]=='}'); e+=1
 return s[a:e]
def main(root):
 s=(root/SOURCE_REL).read_text()
 retry=body(s,'    private func withSessionRetry<T>(').replace('private func withSessionRetry','func withSessionRetry',1)
 ent=body(s,'    private func ensureEntitlementForConnect(').replace('private func ensureEntitlementForConnect','func ensureEntitlementForConnect',1)
 profile=body(s,'    private func resolveProfileForAuthenticatedSession(').replace('private func resolveProfileForAuthenticatedSession','func resolveProfileForAuthenticatedSession',1)
 swift='''import Foundation
struct User { let id:String }; struct AuthSession { let user:User; let accessToken:String }
struct Entitlement: Equatable { let marker:String; var hasPaidAccess:Bool { false } }; struct PreparedTunnel: Equatable { let marker:String }; enum VpnRoutingMode { case fixture }
enum AuthenticatedOperationError: Error { case sessionChanged }
struct FixtureError: Error { let unauthorized:Bool }; extension Error { var isUnauthorizedAPIError:Bool { (self as? FixtureError)?.unauthorized == true } }
@MainActor final class API { var entitlementHook:(() -> Void)?; var entitlementValue=Entitlement(marker:"old"); func entitlement(accessToken:String) async throws -> Entitlement { entitlementHook?(); return entitlementValue } }
@MainActor final class Profile { var hook:(() -> Void)?; var nextError:Error?; func resolveProfile(accessToken:String,locationId:String,routingMode:VpnRoutingMode,forceRefresh:Bool,writeHelperConfig:Bool=true,prevalidatedEntitlement:Entitlement?=nil,accountID:String?=nil,validateCurrent:@MainActor () throws -> Void = {}) async throws -> PreparedTunnel { try validateCurrent(); hook?(); try validateCurrent(); if let nextError { throw nextError }; return PreparedTunnel(marker:accessToken) } }
@MainActor final class Fixture {
 var session:AuthSession?; var user:User?; var authenticatedSessionGeneration=1; var refreshes=0; var expires=0; var statusMessage:String?; var entitlement:Entitlement?; let api=API(); let profileService=Profile()
 var refreshHook:(() -> String?)?; func ensureAuthenticatedSessionCurrent(generation:Int, accessToken:String?=nil, accountID:String?=nil) throws { guard authenticatedSessionGeneration == generation, accessToken.map({ value in session?.accessToken == value }) ?? true, accountID.map({ value in session?.user.id == value }) ?? true else { throw AuthenticatedOperationError.sessionChanged } }; func authenticatedAccessToken() async -> String? { session?.accessToken }; func refreshSessionForRetry() async -> String? { refreshes += 1; if let refreshHook { return refreshHook() }; return session?.accessToken }; func expireAuthenticatedSession(message:String) { expires += 1; session=nil }
'''+retry+'\n'+ent+'\n'+profile+'''\n}
@main struct Probe { @MainActor static func main() async {
 let old=AuthSession(user:User(id:"old"),accessToken:"old"); let replacement=AuthSession(user:User(id:"new"),accessToken:"new")
 func fixture()->Fixture { let f=Fixture(); f.session=old; f.user=old.user; return f }
 // Late first 401 after account replacement must not refresh/retry replacement.
 let first=fixture(); _=await first.withSessionRetry { _ in first.session=replacement; first.user=replacement.user; first.authenticatedSessionGeneration += 1; throw FixtureError(unauthorized:true) }; let firstSafe=first.refreshes==0 && first.expires==0 && first.session?.accessToken=="new"
 // Retry itself crosses into replacement, then a late second 401 must not expire it.
 let second=fixture(); var calls=0; second.refreshHook={ second.session=AuthSession(user:old.user,accessToken:"refreshed"); return "refreshed" }; _=await second.withSessionRetry { _ -> String in calls += 1; if calls==2 { second.session=replacement; second.user=replacement.user; second.authenticatedSessionGeneration += 1 }; throw FixtureError(unauthorized:true) }; let secondSafe=calls==2 && second.expires==0 && second.session?.accessToken=="new"
 // A success produced after the operation switched accounts must be discarded.
 let success=fixture(); let late=await success.withSessionRetry { _ -> String in success.session=replacement; success.user=replacement.user; success.authenticatedSessionGeneration += 1; return "old-result" }; let successSafe=(late == nil)
 // Valid same-session first 401 retries; current-session second 401 still expires.
 let valid=fixture(); var validCalls=0; let validValue=await valid.withSessionRetry { _ -> String in validCalls += 1; if validCalls==1 { throw FixtureError(unauthorized:true) }; return "ok" }; let validRetry=(validValue=="ok" && valid.refreshes==1 && valid.expires==0)
 let expiry=fixture(); _=await expiry.withSessionRetry { _ -> String in throw FixtureError(unauthorized:true) }; let validExpiry=(expiry.expires==1)
 // Entitlement completion from stale operation cannot write to replacement account.
 let staleEnt=fixture(); staleEnt.api.entitlementHook={ staleEnt.session=replacement; staleEnt.user=replacement.user; staleEnt.authenticatedSessionGeneration += 1 }; _=await staleEnt.ensureEntitlementForConnect(accessToken:"old"); let entSafe=(staleEnt.entitlement == nil)
 // Profile completion/stale 401 cannot return, refresh, or expire replacement.
 let staleProfile=fixture(); staleProfile.profileService.hook={ staleProfile.session=replacement; staleProfile.user=replacement.user; staleProfile.authenticatedSessionGeneration += 1 }; let returned=try? await staleProfile.resolveProfileForAuthenticatedSession(accessToken:"old",locationId:"x",routingMode:.fixture,forceRefresh:false); let profileReturnSafe=(returned == nil)
 let stale401=fixture(); stale401.profileService.nextError=FixtureError(unauthorized:true); stale401.profileService.hook={ stale401.session=replacement; stale401.user=replacement.user; stale401.authenticatedSessionGeneration += 1 }; _=try? await stale401.resolveProfileForAuthenticatedSession(accessToken:"old",locationId:"x",routingMode:.fixture,forceRefresh:false); let profile401Safe=(stale401.refreshes==0 && stale401.expires==0 && stale401.session?.accessToken=="new")
 // A nil refresh that completed after replacement must remain a sessionChanged error,
 // never the original unauthorized error that routes to tunnel-failure cleanup.
 let nilRefresh=fixture(); nilRefresh.profileService.nextError=FixtureError(unauthorized:true); nilRefresh.refreshHook={ nilRefresh.session=replacement; nilRefresh.user=replacement.user; nilRefresh.authenticatedSessionGeneration += 1; return nil }
 var nilRefreshSafe=false
 do { _=try await nilRefresh.resolveProfileForAuthenticatedSession(accessToken:"old",locationId:"x",routingMode:.fixture,forceRefresh:false) }
 catch AuthenticatedOperationError.sessionChanged { nilRefreshSafe=true }
 catch { }
 // Same token/account but a new logical login: the actual method must discard the response.
 let relogin=fixture(); let reloginResult=await relogin.withSessionRetry { _ -> String in relogin.session=old; relogin.authenticatedSessionGeneration += 1; return "stale-after-relogin" }; let logoutReloginCancels=(reloginResult == nil)
 let checks:[(String,Bool)]=[("late_first401_does_not_touch_replacement",firstSafe),("late_second401_does_not_expire_replacement",secondSafe),("late_success_discarded",successSafe),("same_account_logout_relogin_generation_cancels",logoutReloginCancels),("valid_same_session_retry",validRetry),("valid_current401_expires",validExpiry),("entitlement_stale_cannot_write",entSafe),("profile_stale_cannot_return",profileReturnSafe),("profile_stale_cannot_refresh_or_expire",profile401Safe),("profile_nil_refresh_after_boundary_is_sessionChanged",nilRefreshSafe)]
 for (n,v) in checks { print("\\(n)=\\(v)") }; exit(checks.allSatisfy{$0.1} ? 0:1)
 } }
'''
 with tempfile.TemporaryDirectory(prefix='vex-auth-lifecycle-', dir=os.environ.get('TMPDIR')) as d:
  p=Path(d); (p/'main.swift').write_text(swift)
  c=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'main.swift'),'-o',str(p/'probe')],text=True,capture_output=True)
  if c.returncode: print(c.stderr,file=sys.stderr); return c.returncode
  return subprocess.run([str(p/'probe')]).returncode
if __name__=='__main__': raise SystemExit(main(Path(sys.argv[1]) if len(sys.argv)==2 else Path(__file__).resolve().parents[2]))
