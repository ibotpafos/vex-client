export type SettingsSectionId = 'connection' | 'routing' | 'interface' | 'account' | 'about';
export type SettingsRowId =
  | 'automation'
  | 'server'
  | 'smart-routing'
  | 'anti-leak'
  | 'applications'
  | 'language'
  | 'dashboard'
  | 'support'
  | 'sign-out'
  | 'version';

export function settingsSectionModel(platform: 'android' | 'ios'): ReadonlyArray<{
  id: SettingsSectionId;
  rows: readonly SettingsRowId[];
}> {
  return [
    { id: 'connection', rows: ['automation'] },
    {
      id: 'routing',
      rows: [
        ...(platform === 'android' ? ['applications' as const] : []),
        'server',
        'smart-routing',
        'anti-leak',
      ],
    },
    { id: 'interface', rows: ['language'] },
    { id: 'account', rows: ['dashboard', 'support', 'sign-out'] },
    { id: 'about', rows: ['version'] },
  ];
}
