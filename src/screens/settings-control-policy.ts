export type SettingsSwitchImplementation = 'expo-ui' | 'react-native';

export function settingsSwitchImplementation(platform: string): SettingsSwitchImplementation {
  return platform === 'android' ? 'react-native' : 'expo-ui';
}
