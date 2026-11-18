const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const test = require('node:test');
const root = process.env.VEX_PROFILE_ERROR_SOURCE_ROOT || path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src/vpn/useVpnConnectionFlow.ts'), 'utf8');
const start = source.indexOf('    const orderedLocations =');
const end = source.indexOf('    if (!androidVpnProfileWithinBinderBudget', start);
assert.ok(start >= 0 && end > start);
const compiled = ts.transpileModule(`return async (availableLocations, resolveCurrentProfile, isProfileResolutionFallbackError) => {
  let profile = null, profileLocationId = 'initial', lastProfileError;
  const explicitConnectProfileResolutionOptions = {};
  const initialLocationId = 'first';
  const protocol = undefined;
  const protocolLocations = availableLocations;
  const profileResolutionOrder = () => availableLocations;
  ${source.slice(start, end)}
  return { profile, profileLocationId };
}`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
const resolve = new Function(compiled)();
const locations = [{ id: 'first' }, { id: 'second' }];
const profile = { config: 'fixture-profile' };

test('ordered profile resolution preserves the last retryable failure', async () => {
  const errors = [new Error('first unavailable'), new Error('second unavailable')];
  await assert.rejects(resolve(locations, async id => { throw errors[id === 'first' ? 0 : 1]; }, () => true), error => error === errors[1]);
});

test('non-fallback auth/session failures cannot be hidden by a later profile', async () => {
  const denied = new Error('session rejected');
  await assert.rejects(resolve(locations, async id => { if (id === 'first') throw denied; return profile; }, () => false), error => error === denied);
});

test('a retryable failure still permits the next ordered profile', async () => {
  const result = await resolve(locations, async id => { if (id === 'first') throw new Error('missing'); return profile; }, () => true);
  assert.equal(result.profile, profile);
  assert.equal(result.profileLocationId, 'second');
});

test('the preferred available location is retained without issuing unused profiles', async () => {
  const issued = [];
  const result = await resolve(locations, async id => { issued.push(id); return id === 'first' ? profile : { config: 'later' }; }, () => true);
  assert.deepEqual(issued, ['first']);
  assert.equal(result.profile, profile);
  assert.equal(result.profileLocationId, 'first');
});
