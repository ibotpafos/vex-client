#!/usr/bin/env node
// Conservative full-audience APK upgrade check. Does not approve publication.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

function parseBadging(text) {
  const pkg = text.match(/^package: name='([^']+)' versionCode='(\d+)'/m);
  const sdk = text.match(/^sdkVersion:'(\d+)'/m);
  const native = text.match(/^native-code: (.+)$/m);
  if (!pkg || !sdk || !native) throw new Error('Incomplete APK metadata');
  return { packageName: pkg[1], versionCode: Number(pkg[2]), minSdk: Number(sdk[1]), abis: [...native[1].matchAll(/'([^']+)'/g)].map(m => m[1]) };
}

function parseSigners(text) {
  const signers = [...text.matchAll(/^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})\s*$/gm)].map(m => m[1].toLowerCase());
  if (!signers.length) throw new Error('No verified APK signing certificates');
  return [...new Set(signers)].sort();
}

function validate(meta) {
  if (!meta || !/^[a-zA-Z]\w*(?:\.[a-zA-Z]\w*)+$/.test(meta.packageName || '') ||
      !Number.isSafeInteger(meta.versionCode) || meta.versionCode < 1 ||
      !Number.isSafeInteger(meta.minSdk) || meta.minSdk < 1 ||
      !Array.isArray(meta.abis) || !meta.abis.length || meta.abis.some(a => !['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64', 'armeabi', 'mips', 'mips64'].includes(a)) ||
      !Array.isArray(meta.signers) || !meta.signers.length || meta.signers.some(s => !/^[a-f0-9]{64}$/.test(s))) {
    throw new Error('Invalid APK identity or platform metadata');
  }
}

function analyzeUpgrade(base, candidate) {
  validate(base); validate(candidate);
  const reasons = [];
  if (base.packageName !== candidate.packageName) reasons.push('PACKAGE_CHANGED');
  if ([...new Set(base.signers)].sort().join(',') !== [...new Set(candidate.signers)].sort().join(',')) reasons.push('SIGNER_CHANGED');
  if (candidate.versionCode <= base.versionCode) reasons.push('BUILD_NOT_INCREASED');
  if (base.abis.some(abi => !candidate.abis.includes(abi))) reasons.push('ABI_REMOVED');
  if (candidate.minSdk > base.minSdk) reasons.push('MIN_SDK_RAISED');
  return reasons;
}

function inspect(apk) {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || path.join(process.env.HOME || '', 'Library/Android/sdk');
  const aapt = process.env.AAPT_BIN || path.join(sdk, 'build-tools/36.0.0/aapt');
  const signer = process.env.APKSIGNER_BIN || path.join(sdk, 'build-tools/36.0.0/apksigner');
  const hash = () => crypto.createHash('sha256').update(fs.readFileSync(apk)).digest('hex');
  const before = hash();
  const options = { encoding: 'utf8', timeout: 60_000, maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] };
  const metadata = parseBadging(execFileSync(aapt, ['dump', 'badging', apk], options));
  metadata.signers = parseSigners(execFileSync(signer, ['verify', '--print-certs', apk], options));
  validate(metadata);
  if (hash() !== before) throw new Error('APK changed during inspection');
  return { ...metadata, sha256: before };
}

if (require.main === module) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: node scripts/verify_android_upgrade.cjs BASELINE.apk CANDIDATE.apk');
    const baseline = inspect(path.resolve(process.argv[2]));
    const candidate = inspect(path.resolve(process.argv[3]));
    const reasons = analyzeUpgrade(baseline, candidate);
    console.log(JSON.stringify({ compatible: reasons.length === 0, reasons, baseline, candidate }, null, 2));
    process.exitCode = reasons.length ? 1 : 0;
  } catch (error) {
    // Do not dump command stderr or environment into release logs.
    const reason = Number.isInteger(error.status) ? `TOOL_FAILED status=${error.status}` : 'INVALID_INPUT_OR_TOOL_UNAVAILABLE';
    console.error('APK_UPGRADE_CHECK_ERROR: ' + reason);
    process.exitCode = 2;
  }
}

module.exports = { analyzeUpgrade, parseBadging, parseSigners };
