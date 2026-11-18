import { vexTheme } from '@/ui/vex-theme';
import { Button, Column, ScrollView, Spacer, Text } from "@expo/ui";
import { defaultMinSize } from '@expo/ui/jetpack-compose/modifiers';
import { frame } from '@expo/ui/swift-ui/modifiers';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Platform, StyleSheet, useWindowDimensions } from "react-native";

import { vexMobileType } from "@/ui/vex-mobile-visual";

type UniversalSignInWelcomeProps = {
  onContinue: () => void;
};

/** Content rendered inside the sign-in screen's shared Expo UI Host. */
export function UniversalSignInWelcome({ onContinue }: UniversalSignInWelcomeProps) {
  const { width, height } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const topPadding = height < 600 ? 24 : 64;
  const minHeight = Math.max(0, height - insets.top - insets.bottom - topPadding - 20);
  const minimumContent = Platform.OS === 'android' ? [defaultMinSize({ minHeight })]
    : Platform.OS === 'ios' ? [frame({ minHeight })] : undefined;
  const contentStyle = { ...styles.content, paddingTop: topPadding, paddingLeft: 24 + insets.left, paddingRight: 24 + insets.right,
    ...(Platform.OS === 'web' ? { minHeight } : null) };

  return (
    <ScrollView>
      <Column alignment="center" spacing={16} style={contentStyle} modifiers={minimumContent}>
        <Spacer flexible />
        <Text textStyle={styles.brand}>VEX</Text>
        <Text textStyle={styles.title}>{"Вход в VEX"}</Text>
        <Text textStyle={styles.subtitle}>Войдите или создайте аккаунт.</Text>
        <Spacer flexible />
        <Button
          label="Продолжить"
          onPress={onContinue}
          style={{ width: Math.max(0, width - insets.left - insets.right - 48), borderRadius: 10 }}
          modifiers={Platform.OS === 'android' ? [defaultMinSize({ minHeight: 48 })] : undefined}
        />
      </Column>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: {
    backgroundColor: vexTheme.colors.background,
    flex: 1,
    paddingBottom: 20,
    paddingHorizontal: 24,
    paddingTop: 64,
  },
  brand: {
    color: "#F2F8F8",
    ...vexMobileType.wordmark,
  },
  title: {
    color: vexTheme.colors.text,
    fontSize: 28,
    fontWeight: "600",
    textAlign: "center",
  },
  subtitle: {
    color: vexTheme.colors.textSecondary,
    fontSize: 16,
    lineHeight: 24,
    textAlign: "center",
  },
});
