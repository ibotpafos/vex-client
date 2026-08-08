export type ProfileSigningKey = Readonly<{
  algorithm: 'ECDSA_P256_SHA256_DER';
  subjectPublicKeyInfoBase64: string;
}>;

// Public trust anchor mirrored from native-windows/packaging/profile-signing-keys.json.
// Keep the parity test in tests/run-unit-tests.ts when rotating this keyring.
export const profileSigningKeys: Readonly<Record<string, ProfileSigningKey>> = Object.freeze({
  'native-profile-p256-v1': Object.freeze({
    algorithm: 'ECDSA_P256_SHA256_DER',
    subjectPublicKeyInfoBase64: 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzELB5rvWLu5lFgES9zkJgs59N97/S2Xi1+11/v1ZpTAyyEb4J5gG3Vq7O+D/ggPjRgT7TadNS074Sc4Rkx8tpg==',
  }),
});
