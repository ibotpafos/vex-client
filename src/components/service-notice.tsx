import { StyleSheet, Text, View } from 'react-native';
import { useServiceNotice } from '@/status/use-service-notice';
import { vexColors } from '@/ui/vex-ui';

export function ServiceNotice() {
  const { notice } = useServiceNotice();
  if (!notice) return null;
  const { title, message, unavailable } = notice;
  return (
    <View accessibilityRole="alert" accessibilityLiveRegion="polite" style={styles.panel} testID="service-notice">
      <Text style={styles.title}>{title}</Text>
      {message ? <Text style={styles.text}>{message}</Text> : null}
      {unavailable ? <Text style={styles.text}>Статус не обновлён. {message ? 'Последнее сообщение; восстановление не подтверждено.' : 'Статус неизвестен. Повторяем проверку.'}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  panel: { backgroundColor: vexColors.card, borderColor: vexColors.line, borderRadius: 16, borderWidth: 1, padding: 16, gap: 8 },
  title: { color: vexColors.textSoft, fontSize: 14, fontWeight: '600' },
  text: { color: vexColors.textSoft, fontSize: 13, lineHeight: 20 },
});
