import { StyleSheet, Text, View } from 'react-native';
import { useServiceNotice } from '@/status/use-service-notice';
import { vexColors } from '@/ui/vex-ui';

export function ServiceNotice() {
  const { config, unavailable } = useServiceNotice();
  const message = config?.incidentBanner?.trim();
  if (!message && !unavailable) return null;
  return (
    <View accessibilityRole="alert" accessibilityLiveRegion="polite" style={styles.panel} testID="service-notice">
      <Text style={styles.title}>{message ? 'Технические работы и неполадки VPN' : 'Статус VPN уточняется'}</Text>
      {message ? <Text style={styles.text}>{message}</Text> : null}
      {unavailable ? <Text style={styles.text}>Не удалось обновить статус. {message ? 'Показано последнее известное сообщение; восстановление пока не подтверждено.' : 'Текущее состояние сервиса неизвестно. Повторяем проверку автоматически.'}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  panel: { backgroundColor: 'rgba(34,211,238,0.08)', borderColor: 'rgba(34,211,238,0.22)', borderRadius: 12, borderWidth: 1, padding: 10, gap: 6 },
  title: { color: vexColors.textSoft, fontSize: 14, fontWeight: '900' },
  text: { color: vexColors.muted, fontSize: 13, lineHeight: 18 },
});
