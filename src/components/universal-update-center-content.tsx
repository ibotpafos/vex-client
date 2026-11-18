import { vexTheme } from "@/ui/vex-theme";
import { Button, Column, Host, List, ListItem, Text } from "@expo/ui";

export type UniversalUpdateCenterContentProps = {
  actionError: string | null;
  actionLabel: string;
  changelog: string | null;
  footnote: string;
  isChecking: boolean;
  onClose: () => void;
  onPrimaryPress: () => void;
  onRefresh: () => void;
  primaryDisabled: boolean;
  statusMessage: string;
  statusTitle: string;
  updateError: boolean;
  values: { label: string; value: string }[];
};

export function UniversalUpdateCenterContent({
  actionError,
  actionLabel,
  changelog,
  footnote,
  isChecking,
  onClose,
  onPrimaryPress,
  onRefresh,
  primaryDisabled,
  statusMessage,
  statusTitle,
  updateError,
  values,
}: UniversalUpdateCenterContentProps) {
  return (
    <Host colorScheme="dark" seedColor={vexTheme.colors.accent} style={styles.host} useViewportSizeMeasurement>
      <Column spacing={8} style={styles.content}>
        <List>
          <ListItem leading="‹" onPress={onClose}>Обновления</ListItem>
        </List>
        <Text textStyle={styles.eyebrow}>Система</Text>
        <Text textStyle={styles.title}>{statusTitle}</Text>
        <Text textStyle={styles.message}>{statusMessage}</Text>
        <List>
          {values.map((item) => (
            <ListItem key={item.label} supportingText={item.value}>{item.label}</ListItem>
          ))}
          {changelog ? <ListItem supportingText={changelog}>Что нового</ListItem> : null}
          {updateError ? <ListItem supportingText="Проверьте подключение и повторите">Не удалось проверить обновления</ListItem> : null}
          {actionError ? <ListItem supportingText={actionError}>Не удалось выполнить действие</ListItem> : null}
        </List>
        <Button disabled={isChecking} label={isChecking ? "Проверяем…" : "Проверить"} onPress={onRefresh} variant="outlined" />
        <Button
          disabled={primaryDisabled}
          label={actionLabel}
          onPress={onPrimaryPress}
        />
        <Text textStyle={styles.footnote}>{footnote}</Text>
      </Column>
    </Host>
  );
}

const styles = {
  content: {
    backgroundColor: vexTheme.colors.background,
    paddingBottom: 20,
    paddingHorizontal: 20,
  },
  eyebrow: {
    color: vexTheme.colors.textMuted,
    fontSize: 12,
    fontWeight: "600" as const,
  },
  footnote: {
    color: vexTheme.colors.textSecondary,
    fontSize: 13,
    lineHeight: 20,
  },
  host: {
    flex: 1,
  },
  message: {
    color: vexTheme.colors.textSecondary,
    fontSize: 15,
    lineHeight: 24,
  },
  title: {
    color: vexTheme.colors.text,
    fontSize: 28,
    fontWeight: "600" as const,
  },
};
