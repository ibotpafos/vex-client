#!/usr/bin/env python3
"""Offline policy/HTTP tests using cached Kotlin/JUnit/OkHttp, never Gradle/Android."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
CACHE = Path(os.environ.get("VEX_KOTLIN_JVM_CACHE", "/Volumes/D/Projects/.dev-cache/vex/releases/vex-client/gradle-user-home/caches/modules-2/files-2.1"))
JAVA = os.environ.get("VEX_KOTLIN_JVM_JAVA") or ("/opt/homebrew/opt/openjdk@17/bin/java" if Path("/opt/homebrew/opt/openjdk@17/bin/java").exists() else shutil.which("java"))


def jar(group, artifact, version):
    matches = list((CACHE / group / artifact / version).glob("*/*.jar"))
    if len(matches) != 1:
        raise SystemExit(f"Required cached jar missing/ambiguous: {group}/{artifact}/{version}")
    return str(matches[0])


def main():
    if not JAVA:
        raise SystemExit("A local JDK is required; this runner never installs dependencies")
    kotlin = "2.1.20"
    stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", kotlin)
    junit = jar("junit", "junit", "4.13.2")
    hamcrest = jar("org.hamcrest", "hamcrest-core", "1.3")
    annotations = jar("org.jetbrains", "annotations", "23.0.0")
    compiler = [jar("org.jetbrains.kotlin", name, kotlin) for name in ["kotlin-compiler-embeddable", "kotlin-script-runtime", "kotlin-reflect", "kotlin-daemon-embeddable"]]
    compiler += [stdlib, annotations, jar("org.jetbrains.intellij.deps", "trove4j", "1.0.20200330"), jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0")]
    deps = [stdlib, junit, hamcrest, annotations, jar("com.squareup.okhttp3", "okhttp", "4.12.0"), jar("com.squareup.okio", "okio-jvm", "3.6.0")]
    source = ROOT / "android/app/src"
    files = [source / "main/java/com/vexguard/app/vpn" / name for name in ["ApiRecoveryPolicy.kt", "ApiHttpSafety.kt"]]
    files += [source / "test/java/com/vexguard/app/vpn" / name for name in ["ApiRecoveryPolicyTest.kt", "ApiHttpSafetyTest.kt"]]
    with tempfile.TemporaryDirectory(prefix="api-http-jvm-", dir="/Volumes/D/tmp" if Path("/Volumes/D/tmp").is_dir() else None) as temp:
        subprocess.run([JAVA, "-Xmx256m", "-cp", os.pathsep.join(compiler), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", os.pathsep.join(deps), "-d", temp, *map(str, files)], check=True, timeout=45)
        subprocess.run([JAVA, "-Xmx128m", "-cp", os.pathsep.join([temp, *deps]), "org.junit.runner.JUnitCore", "com.vexguard.app.vpn.ApiRecoveryPolicyTest", "com.vexguard.app.vpn.ApiHttpSafetyTest"], check=True, timeout=45)
    module = (source / "main/java/com/vexguard/app/vpn/VexVpnModule.kt").read_text()
    transport = (source / "main/java/com/vexguard/app/vpn/ApiRecoveryTransport.kt").read_text()
    assert '(super.getConstants() ?: emptyMap()).toMutableMap()' in module
    for flag in ["apiMutationNoReplay", "apiRecoveryPreservesHttpErrors"]:
        assert f'this["{flag}"] = true' in module
    assert 'this["apiRecoveryHosts"] = ApiRecoveryPolicy.recoveryHosts()' in module
    assert 'private val apiMutationTransport = ApiRecoveryTransport(mutationsOnly = true)' in module
    assert 'apiMutationTransport.request(id, url, method, headers, body, deadlineEpochMillis, promise)' in module
    assert 'fun cancelApiMutation(id: String) { apiMutationTransport.cancel(id) }' in module
    assert 'apiMutationTransport.close()' in module
    mutation_branch = transport.split('if (mutationsOnly) {', 1)[1].split('} else {', 1)[0]
    assert 'check(selectNetwork == null)' in mutation_branch
    assert 'socketFactory(' not in mutation_branch and '.dns(' not in mutation_branch
    assert 'val knownHttp = if (error is ApiHttpError) error.reply else httpError.get()' in transport
    assert 'require(!mutationsOnly || ApiRecoveryPolicy.acceptsMutationMethod(verb))' in transport
    print("PASS: bridge capability/ABI/default-routing/header-retention source contracts")


if __name__ == "__main__":
    main()
