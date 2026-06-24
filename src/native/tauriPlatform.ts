import { Platform } from 'react-native';

export function isTauriRuntime(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}
