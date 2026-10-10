import * as SecureStore from './secureStore';
import { createInstallationUUID, getOrCreateDeviceId } from './appInfo';
import { generateWireGuardKeyPair, getOrCreateWireGuardKeyPair, type WireGuardKeyPair } from './vexVpn';
import type { VpnDevice } from '../api/types';
import { SessionOperationSupersededError } from '../vpn/sessionOperation';

const registrationPrefix = 'vex.vpn.account_registration.v1.';
const keyPrefix = 'vex.vpn.account_keys.v1.';
const legacyKeyOwnerKey = 'vex.vpn.legacy_key_owner.v1';
const accountOperations = new Map<string, Promise<unknown>>();
let legacyKeyAdmission: Promise<unknown> = Promise.resolve();

export type VpnAccountIdentity = {
  installationId: string;
  externalDeviceId: string;
  keyScope: string;
  legacyOwnedDeviceId?: string;
  legacyRegistrationPending?: boolean;
  keyPair: WireGuardKeyPair;
  ownedDevices?: VpnDevice[];
};
export type VpnAccountIdentityOptions = {
  userId: string;
  platform: 'android' | 'ios';
  locationId: string;
  loadOwnedDevices: () => Promise<VpnDevice[]>;
  isCurrentSessionOperation?: () => boolean;
};

function requireCurrent(options: Pick<VpnAccountIdentityOptions, 'isCurrentSessionOperation'>): void {
  if (options.isCurrentSessionOperation && !options.isCurrentSessionOperation()) throw new SessionOperationSupersededError();
}
function registrationKey(userId: string): string {
  if (!userId.trim()) throw new Error('Не удалось определить аккаунт VPN.');
  // SecureStore key restrictions exclude URI escapes. UTF-8 hex is injective.
  return registrationPrefix + Array.from(new TextEncoder().encode(userId.trim()), byte => byte.toString(16).padStart(2, '0')).join('');
}
export function vpnAccountRegistrationIdempotencyKey(userId: string, installationId: string, locationId: string): string {
  return `native-register-${registrationKey(userId).slice(registrationPrefix.length)}-${requireScope(installationId)}-${locationId}`;
}
function requireScope(value: unknown): string {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9._-]{1,160}$/.test(value)) throw new Error('Сохранённая регистрация VPN повреждена.');
  return value;
}
export function validatedVpnAccountKeyPair(value: unknown): WireGuardKeyPair {
  const pair = value as Partial<WireGuardKeyPair> | null;
  const validKey = (key: unknown): key is string => typeof key === 'string' && /^[a-zA-Z0-9+/]{43}=$/.test(key) && atob(key).length === 32 && btoa(atob(key)) === key;
  if (!pair || !validKey(pair.privateKey) || !validKey(pair.publicKey) || !Number.isSafeInteger(pair.keyEpoch) || (pair.keyEpoch ?? 0) < 1) throw new Error('Сохранённый ключ VPN повреждён.');
  return { privateKey: pair.privateKey, publicKey: pair.publicKey, keyEpoch: pair.keyEpoch };
}
export async function saveVpnAccountKeyPair(keyScope: string, pair: WireGuardKeyPair, isCurrentSessionOperation?: () => boolean): Promise<void> {
  const options = { isCurrentSessionOperation };
  requireCurrent(options);
  await SecureStore.setItemAsync(keyPrefix + requireScope(keyScope), JSON.stringify(validatedVpnAccountKeyPair(pair)));
  requireCurrent(options);
}
export async function pendingVpnAccountKeyPair(keyScope: string, isCurrentSessionOperation?: () => boolean): Promise<WireGuardKeyPair | undefined> {
  const options = { isCurrentSessionOperation };
  requireCurrent(options);
  const raw = await SecureStore.getItemAsync(keyPrefix + requireScope(keyScope) + '.pending');
  requireCurrent(options);
  return raw === null ? undefined : validatedVpnAccountKeyPair(JSON.parse(raw));
}
export async function savePendingVpnAccountKeyPair(keyScope: string, pair: WireGuardKeyPair, isCurrentSessionOperation?: () => boolean): Promise<void> {
  const options = { isCurrentSessionOperation };
  requireCurrent(options);
  await SecureStore.setItemAsync(keyPrefix + requireScope(keyScope) + '.pending', JSON.stringify(validatedVpnAccountKeyPair(pair)));
  requireCurrent(options);
}
export async function clearPendingVpnAccountKeyPair(keyScope: string, isCurrentSessionOperation?: () => boolean): Promise<void> {
  const options = { isCurrentSessionOperation };
  requireCurrent(options);
  await SecureStore.deleteItemAsync(keyPrefix + requireScope(keyScope) + '.pending');
  requireCurrent(options);
}
function legacyDevice(devices: VpnDevice[], legacyId: string, options: VpnAccountIdentityOptions): VpnDevice | undefined {
  if (devices.some(device => device.userId && device.userId !== options.userId)) throw new Error('Список VPN-устройств принадлежит другому аккаунту.');
  const candidates = devices.filter(device => device.status === 'active' && device.protocol === 'amneziawg' &&
    (!device.provisioningMode || device.provisioningMode === 'managed_native') &&
    (!device.clientKeyOwnership || device.clientKeyOwnership === 'client') &&
    (device.provisioningMode === 'managed_native' || device.clientKeyOwnership === 'client') &&
    (!device.platform || device.platform === options.platform) &&
    (device.externalDeviceId === legacyId || device.externalDeviceId?.startsWith(`${legacyId}:`)));
  const exact = candidates.filter(device => device.externalDeviceId === legacyId);
  const location = candidates.filter(device => device.externalDeviceId === `${legacyId}:${options.locationId}`);
  const preferred = exact.length ? exact : location.length ? location : candidates;
  if (preferred.length > 1) throw new Error('Найдены неоднозначные прежние регистрации VPN.');
  return preferred[0];
}
function admitLegacyKey(options: VpnAccountIdentityOptions, pair: WireGuardKeyPair): Promise<WireGuardKeyPair | undefined> {
  const pending = legacyKeyAdmission.catch(() => undefined).then(async () => {
    requireCurrent(options);
    const owner = await SecureStore.getItemAsync(legacyKeyOwnerKey);
    requireCurrent(options);
    if (owner !== null && (!owner.startsWith(registrationPrefix) || !/^(?:[a-f0-9]{2})+$/.test(owner.slice(registrationPrefix.length)))) throw new Error('Сохранённый владелец прежнего VPN-ключа повреждён.');
    const account = registrationKey(options.userId);
    if (owner !== null && owner !== account) return undefined;
    if (owner === null) {
      // First live-proven owner wins permanently. Historical unsigned rows
      // under A and B can share even the old WG public key; never copy it twice.
      await SecureStore.setItemAsync(legacyKeyOwnerKey, account);
      requireCurrent(options);
    }
    return pair;
  });
  legacyKeyAdmission = pending;
  return pending;
}
async function resolveAccountIdentity(options: VpnAccountIdentityOptions): Promise<VpnAccountIdentity> {
  requireCurrent(options);
  const mappingKey = registrationKey(options.userId);
  const raw = await SecureStore.getItemAsync(mappingKey);
  requireCurrent(options);
  if (raw !== null) {
    if (!raw) throw new Error('Сохранённая регистрация VPN повреждена.');
    const mapping = JSON.parse(raw) as { version?: unknown; installationId?: unknown; externalDeviceId?: unknown; keyScope?: unknown; legacyOwnedDeviceId?: unknown; legacyRegistrationPending?: unknown };
    if (!mapping || mapping.version !== 1) throw new Error('Сохранённая регистрация VPN повреждена.');
    const installationId = requireScope(mapping.installationId), externalDeviceId = requireScope(mapping.externalDeviceId), keyScope = requireScope(mapping.keyScope);
    const stored = await SecureStore.getItemAsync(keyPrefix + keyScope);
    requireCurrent(options);
    if (!stored) throw new Error('Сохранённый ключ аккаунта VPN недоступен.');
    const legacyOwnedDeviceId = mapping.legacyOwnedDeviceId === undefined ? undefined : requireScope(mapping.legacyOwnedDeviceId);
    if (mapping.legacyRegistrationPending !== undefined && typeof mapping.legacyRegistrationPending !== 'boolean') throw new Error('Сохранённая регистрация VPN повреждена.');
    const legacyRegistrationPending = mapping.legacyRegistrationPending === undefined ? Boolean(legacyOwnedDeviceId) : mapping.legacyRegistrationPending;
    return { installationId, externalDeviceId, keyScope, legacyOwnedDeviceId, legacyRegistrationPending, keyPair: validatedVpnAccountKeyPair(JSON.parse(stored)) };
  }
  // A successful live lookup is required before adopting or allocating an ID.
  const ownedDevices = await options.loadOwnedDevices();
  requireCurrent(options);
  const legacyId = await getOrCreateDeviceId();
  requireCurrent(options);
  const existing = legacyDevice(ownedDevices, legacyId, options);
  const installationId = existing ? requireScope(legacyId) : `vexd_${createInstallationUUID()}`;
  const externalDeviceId = installationId;
  // Old unverified rows can have the same external ID under different users.
  // The key namespace must stay distinct even when both adopt that old ID.
  const keyScope = `vexk_${createInstallationUUID()}`;
  let keyPair: WireGuardKeyPair;
  if (existing) {
    const legacyPair = await getOrCreateWireGuardKeyPair();
    requireCurrent(options);
    const matched = existing.publicKey && legacyPair?.publicKey === existing.publicKey
      ? await admitLegacyKey(options, validatedVpnAccountKeyPair({ ...legacyPair, keyEpoch: Number.isSafeInteger(existing.keyEpoch) && (existing.keyEpoch ?? 0) > 0 ? existing.keyEpoch : legacyPair.keyEpoch ?? 1 })) : undefined;
    keyPair = matched ?? await generatedAccountKeyPair(options);
  } else keyPair = await generatedAccountKeyPair(options);
  requireCurrent(options);
  await saveVpnAccountKeyPair(keyScope, keyPair, options.isCurrentSessionOperation);
  // Registration cannot start unless the key and account mapping are durable.
  const legacyOwnedDeviceId = existing?.id;
  const legacyRegistrationPending = Boolean(existing);
  await SecureStore.setItemAsync(mappingKey, JSON.stringify({ version: 1, installationId, externalDeviceId, keyScope, legacyOwnedDeviceId, legacyRegistrationPending }));
  requireCurrent(options);
  return { installationId, externalDeviceId, keyScope, legacyOwnedDeviceId, legacyRegistrationPending, keyPair, ownedDevices };
}

export async function renewVpnAccountInstallation(options: VpnAccountIdentityOptions, identity: VpnAccountIdentity): Promise<VpnAccountIdentity> {
  requireCurrent(options);
  const renewed = { ...identity, installationId: `vexd_${createInstallationUUID()}`, legacyRegistrationPending: true };
  await persistVpnAccountRegistration(options, renewed);
  requireCurrent(options);
  return renewed;
}
export async function confirmVpnAccountRegistration(options: VpnAccountIdentityOptions, identity: VpnAccountIdentity): Promise<void> {
  await persistVpnAccountRegistration(options, { ...identity, legacyRegistrationPending: false });
}
async function persistVpnAccountRegistration(options: VpnAccountIdentityOptions, identity: VpnAccountIdentity): Promise<void> {
  requireCurrent(options);
  await SecureStore.setItemAsync(registrationKey(options.userId), JSON.stringify({ version: 1, installationId: identity.installationId, externalDeviceId: identity.externalDeviceId, keyScope: identity.keyScope, legacyOwnedDeviceId: identity.legacyOwnedDeviceId, legacyRegistrationPending: identity.legacyRegistrationPending }));
  requireCurrent(options);
}
async function generatedAccountKeyPair(options: VpnAccountIdentityOptions): Promise<WireGuardKeyPair> {
  requireCurrent(options);
  const generated = await generateWireGuardKeyPair();
  requireCurrent(options);
  return validatedVpnAccountKeyPair(generated && { ...generated, keyEpoch: 1 });
}
export function withVpnAccountIdentity<T>(options: VpnAccountIdentityOptions, use: (identity: VpnAccountIdentity) => Promise<T>): Promise<T> {
  const key = registrationKey(options.userId);
  const previous = accountOperations.get(key) ?? Promise.resolve();
  const pending = previous.catch(() => undefined).then(async () => {
    requireCurrent(options);
    const identity = await resolveAccountIdentity(options);
    requireCurrent(options);
    return use(identity);
  });
  accountOperations.set(key, pending);
  const release = () => { if (accountOperations.get(key) === pending) accountOperations.delete(key); };
  void pending.then(release, release);
  return pending;
}
export function getOrCreateVpnAccountIdentity(options: VpnAccountIdentityOptions): Promise<VpnAccountIdentity> {
  return withVpnAccountIdentity(options, async identity => identity);
}
