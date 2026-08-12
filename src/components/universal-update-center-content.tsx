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
    <Host colorScheme="dark" style={styles.host} useViewportSizeMeasurement>
      <Column spacing={8} style={styles.content}>
        <List>
          <ListItem leading="‹" onPress={onClose}>Обновления</ListItem>
          <ListItem supportingText={statusMessage}>{statusTitle}</ListItem>
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
    backgroundColor: "#041315",
    paddingBottom: 12,
  },
  footnote: {
    color: "#A7B9BD",
    fontSize: 13,
    lineHeight: 18,
  },
  host: {
    flex: 1,
  },
};
