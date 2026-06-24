import { Redirect } from 'expo-router';

export default function SupportTabProxy() {
  return <Redirect href="/(app)/(tabs)/index" />;
}
