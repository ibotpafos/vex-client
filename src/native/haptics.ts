import * as Haptics from 'expo-haptics';
import { Platform } from 'react-native';

const supportsHaptics = Platform.OS === 'android' || Platform.OS === 'ios';

function runHapticFeedback(action: () => Promise<void>): void {
  if (!supportsHaptics) {
    return;
  }
  action().catch(() => undefined);
}

export function playSelectionHaptic(): void {
  runHapticFeedback(() => Haptics.selectionAsync());
}

export function playLightImpactHaptic(): void {
  runHapticFeedback(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light));
}

export function playMediumImpactHaptic(): void {
  runHapticFeedback(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium));
}

export function playSuccessHaptic(): void {
  runHapticFeedback(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success));
}

export function playWarningHaptic(): void {
  runHapticFeedback(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning));
}

export function playErrorHaptic(): void {
  runHapticFeedback(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error));
}
