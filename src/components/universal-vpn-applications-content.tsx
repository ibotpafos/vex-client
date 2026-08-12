import {
  Button,
  Column,
  Host,
  List,
  ListItem,
  Spacer,
  Text,
  TextInput,
} from "@expo/ui";
import type { InstalledVpnApplication } from "@/native/vexVpn";

export type UniversalVpnApplicationsContentProps = {
  applications: InstalledVpnApplication[];
  loading: boolean;
  mode: "all" | "selected";
  onBack: () => void;
  onModeChange: (mode: "all" | "selected") => void;
  onQueryChange: (query: string) => void;
  onToggleApplication: (packageName: string) => void;
  selectedPackages: ReadonlySet<string>;
};

export function UniversalVpnApplicationsContent({
  applications,
  loading,
  mode,
  onBack,
  onModeChange,
  onQueryChange,
  onToggleApplication,
  selectedPackages,
}: UniversalVpnApplicationsContentProps) {
  return (
    <Host colorScheme="dark" style={styles.host} useViewportSizeMeasurement>
      <Column spacing={8} style={styles.content}>
        <List>
          <ListItem leading="‹" onPress={onBack}>Приложения через VPN</ListItem>
        </List>
        <Text textStyle={styles.description}>
          Выберите приложения для VPN. Изменения применятся при следующем подключении.
        </Text>
        <Column spacing={6} style={styles.modeRow}>
          <Button label="Все приложения" onPress={() => onModeChange("all")} variant={mode === "all" ? "filled" : "outlined"} />
          <Button
            label={`Выбранные (${selectedPackages.size})`}
            onPress={() => onModeChange("selected")}
            variant={mode === "selected" ? "filled" : "outlined"}
          />
        </Column>
        <TextInput
          autoCapitalize="none"
          autoCorrect={false}
          onChangeText={onQueryChange}
          placeholder="Поиск приложений"
          returnKeyType="search"
        />
        <List testID="vpn-applications-list">
          {loading ? (
            <ListItem supportingText="Это займёт несколько секунд">Загружаем приложения…</ListItem>
          ) : applications.length === 0 ? (
            <ListItem supportingText="Измените поисковый запрос">Ничего не найдено</ListItem>
          ) : applications.map((application) => {
            const selected = selectedPackages.has(application.packageName);
            return (
              <ListItem
                key={application.packageName}
                leading={selected ? "✓" : "○"}
                onPress={() => onToggleApplication(application.packageName)}
                supportingText={application.packageName}
                testID={`vpn-application-${application.packageName}`}
                trailing={selected ? "VPN" : undefined}
              >
                {application.label}
              </ListItem>
            );
          })}
        </List>
        <Spacer />
      </Column>
    </Host>
  );
}

const styles = {
  content: {
    backgroundColor: "#041315",
    paddingBottom: 12,
  },
  description: {
    color: "#A7B9BD",
    fontSize: 14,
    lineHeight: 20,
  },
  host: {
    flex: 1,
  },
  modeRow: {
    paddingBottom: 4,
  },
};
