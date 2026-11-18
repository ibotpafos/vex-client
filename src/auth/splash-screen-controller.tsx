import * as SplashScreen from 'expo-splash-screen';
import { useEffect } from 'react';
import { useSession } from '@/auth/session-context';

void SplashScreen.preventAutoHideAsync();

export function SplashScreenController() {
  const { isLoading } = useSession();

  useEffect(() => {
    if (isLoading) {
      return;
    }
    void SplashScreen.hideAsync();
  }, [isLoading]);

  return null;
}
