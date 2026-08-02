export type ManagedAmneziaConfig = {
  jc?: number;
  jmin?: number;
  jmax?: number;
  s1?: number;
  s2?: number;
  s3?: number;
  s4?: number;
  h1?: string;
  h2?: string;
  h3?: string;
  h4?: string;
  i1?: string;
  i2?: string;
  i3?: string;
  i4?: string;
  i5?: string;
  header_protection_key?: string;
  content_padding_addition?: string;
  rekey_after_time?: string;
  rekey_timeout?: string;
  reject_after_time?: string;
  keepalive_timeout?: string;
  max_handshake_attempts?: string;
};

export function managedProfileAmneziaConfig(amnezia?: ManagedAmneziaConfig): string {
  if (!amnezia) {
    return '';
  }
  const lines: string[] = [];
  const addNumber = (key: string, value?: number) => {
    if (typeof value === 'number' && value !== 0) {
      lines.push(`${key} = ${value}`);
    }
  };
  const addString = (key: string, value?: string) => {
    const normalized = value?.trim();
    if (normalized) {
      lines.push(`${key} = ${normalized}`);
    }
  };
  addNumber('Jc', amnezia.jc);
  addNumber('Jmin', amnezia.jmin);
  addNumber('Jmax', amnezia.jmax);
  addNumber('S1', amnezia.s1);
  addNumber('S2', amnezia.s2);
  addNumber('S3', amnezia.s3);
  addNumber('S4', amnezia.s4);
  addString('H1', amnezia.h1);
  addString('H2', amnezia.h2);
  addString('H3', amnezia.h3);
  addString('H4', amnezia.h4);
  addString('I1', amnezia.i1);
  addString('I2', amnezia.i2);
  addString('I3', amnezia.i3);
  addString('I4', amnezia.i4);
  addString('I5', amnezia.i5);
  addString('HeaderProtectionKey', amnezia.header_protection_key);
  addString('ContentPaddingAddition', amnezia.content_padding_addition);
  addString('RekeyAfterTime', amnezia.rekey_after_time);
  addString('RekeyTimeout', amnezia.rekey_timeout);
  addString('RejectAfterTime', amnezia.reject_after_time);
  addString('KeepaliveTimeout', amnezia.keepalive_timeout);
  addString('MaxHandshakeAttempts', amnezia.max_handshake_attempts);
  return lines.length ? `${lines.join('\n')}\n` : '';
}
