import { Button, Column, Spacer, Text } from "@expo/ui";
import { StyleSheet, useWindowDimensions } from "react-native";

type UniversalSignInWelcomeProps = {
  onContinue: () => void;
};

/** Content rendered inside the sign-in screen's shared Expo UI Host. */
export function UniversalSignInWelcome({ onContinue }: UniversalSignInWelcomeProps) {
  const { width } = useWindowDimensions();

  return (
    <Column alignment="center" spacing={16} style={styles.content}>
      <Spacer flexible />
      <Text textStyle={styles.brand}>VEX</Text>
      <Text textStyle={styles.title}>Давайте подключимся</Text>
      <Text textStyle={styles.subtitle}>Войдите, чтобы получить доступ к своему VPN.</Text>
      <Spacer flexible />
      <Button
        label="Войти или создать аккаунт"
        onPress={onContinue}
        style={{ width: Math.max(280, width - 48) }}
      />
    </Column>
  );
}

const styles = StyleSheet.create({
  content: {
    backgroundColor: "#041315",
    flex: 1,
    paddingBottom: 20,
    paddingHorizontal: 24,
    paddingTop: 64,
  },
  brand: {
    color: "#43D9E7",
    fontSize: 26,
    fontWeight: "800",
    letterSpacing: 3,
  },
  title: {
    color: "#F1FBFC",
    fontSize: 32,
    fontWeight: "800",
    textAlign: "center",
  },
  subtitle: {
    color: "#91A8AC",
    fontSize: 16,
    lineHeight: 22,
    textAlign: "center",
  },
});
