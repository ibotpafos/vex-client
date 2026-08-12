import {
  FieldGroup,
  Host,
  ListItem,
  Picker,
  Switch,
} from "@expo/ui";

export type UniversalSettingsContentProps = {
  antiLeakEnabled: boolean;
  applicationRoutingSummary: string;
  autoServerSelectionEnabled: boolean;
  automationEnabled: boolean;
  automationHint: string;
  automationTitle: string;
  buildText: string | null;
  channel: string;
  coreVersion: string;
  isAndroidApp: boolean;
  isSavingAntiLeak: boolean;
  isSavingAutomation: boolean;
  isSavingServerSelection: boolean;
  isSavingSmartRouting: boolean;
  isSigningOut: boolean;
  language: string;
  onAntiLeakChange: (value: boolean) => void;
  onApplicationRoutingPress: () => void;
  onAutoServerSelectionChange: (value: boolean) => void;
  onAutomationChange: (value: boolean) => void;
  onBack: () => void;
  onDashboardPress: () => void;
  onLanguageChange: (value: string) => void;
  onSignOut: () => void;
  onSmartRoutingChange: (value: boolean) => void;
  onSupportPress: () => void;
  platform: string;
  routingPolicyVersion: string;
  smartRoutingEnabled: boolean;
  smartRoutingHint: string;
  versionText: string;
};

export function UniversalSettingsContent({
  antiLeakEnabled,
  applicationRoutingSummary,
  autoServerSelectionEnabled,
  automationEnabled,
  automationHint,
  automationTitle,
  buildText,
  channel,
  coreVersion,
  isAndroidApp,
  isSavingAntiLeak,
  isSavingAutomation,
  isSavingServerSelection,
  isSavingSmartRouting,
  isSigningOut,
  language,
  onAntiLeakChange,
  onApplicationRoutingPress,
  onAutoServerSelectionChange,
  onAutomationChange,
  onBack,
  onDashboardPress,
  onLanguageChange,
  onSignOut,
  onSmartRoutingChange,
  onSupportPress,
  platform,
  routingPolicyVersion,
  smartRoutingEnabled,
  smartRoutingHint,
  versionText,
}: UniversalSettingsContentProps) {
  return (
    <Host colorScheme="dark" style={styles.host} useViewportSizeMeasurement>
      <FieldGroup style={styles.group}>
        <FieldGroup.Section title="VEX VPN">
          <ListItem onPress={onBack} supportingText="Вернуться к подключению" trailing="‹">
            Настройки
          </ListItem>
          <ListItem
            supportingText={[platform, buildText, channel].filter(Boolean).join(" · ")}
          >
            Версия {versionText}
          </ListItem>
        </FieldGroup.Section>

        <FieldGroup.Section title="Подключение">
          <ListItem
            supportingText={automationHint}
            trailing={(
              <Switch
                disabled={isSavingAutomation}
                onValueChange={onAutomationChange}
                testID="settings-automation-switch"
                value={automationEnabled}
              />
            )}
          >
            {automationTitle}
          </ListItem>
          {isAndroidApp ? (
            <ListItem
              onPress={onApplicationRoutingPress}
              supportingText="Все приложения или только выбранные"
              trailing={applicationRoutingSummary}
            >
              Приложения через VPN
            </ListItem>
          ) : null}
          <ListItem
            supportingText="Выбирать лучший доступный сервер при подключении"
            trailing={(
              <Switch
                disabled={isSavingServerSelection}
                onValueChange={onAutoServerSelectionChange}
                testID="settings-auto-server-switch"
                value={autoServerSelectionEnabled}
              />
            )}
          >
            Автовыбор сервера
          </ListItem>
          <ListItem
            supportingText={smartRoutingHint}
            trailing={(
              <Switch
                disabled={isSavingSmartRouting}
                onValueChange={onSmartRoutingChange}
                testID="settings-smart-routing-switch"
                value={smartRoutingEnabled}
              />
            )}
          >
            Умный режим
          </ListItem>
          <ListItem
            supportingText="Блокировать прямой интернет при аварийном обрыве VPN"
            trailing={(
              <Switch
                disabled={isSavingAntiLeak}
                onValueChange={onAntiLeakChange}
                testID="settings-anti-leak-switch"
                value={antiLeakEnabled}
              />
            )}
          >
            Защита от утечки IP
          </ListItem>
        </FieldGroup.Section>

        <FieldGroup.Section title="Интерфейс">
          <ListItem
            supportingText="Язык интерфейса приложения"
            trailing={(
              <Picker
                onValueChange={onLanguageChange}
                selectedValue={language}
                testID="settings-language-picker"
              >
                <Picker.Item label="Русский" value="ru" />
                <Picker.Item label="English" value="en" />
              </Picker>
            )}
          >
            Язык
          </ListItem>
        </FieldGroup.Section>

        <FieldGroup.Section title="Аккаунт и помощь">
          <ListItem onPress={onDashboardPress} supportingText="Подписка, оплата и устройства — на сайте VEX" trailing="›">
            Личный кабинет
          </ListItem>
          <ListItem onPress={onSupportPress} supportingText="Открыть сайт VEX и написать в поддержку" trailing="›">
            Поддержка
          </ListItem>
          <ListItem onPress={isSigningOut ? undefined : onSignOut} supportingText={isSigningOut ? "Завершаем сеанс" : "Выйти только с этого устройства"}>
            Выйти из аккаунта
          </ListItem>
        </FieldGroup.Section>

        <FieldGroup.Section title="Система">
          <ListItem supportingText={coreVersion}>Ядро VPN</ListItem>
          <ListItem supportingText={routingPolicyVersion}>Политика маршрутизации</ListItem>
        </FieldGroup.Section>
      </FieldGroup>
    </Host>
  );
}

const styles = {
  group: {
    backgroundColor: "#041315",
  },
  host: {
    flex: 1,
  },
};
