import { useEffect, useRef } from 'react';
import { Animated, Easing, Platform } from 'react-native';
import { isTauriRuntime, type ConnectionPhase } from '../screens/home-screen-helpers';
import { vpnConnectionAnimationsEnabled } from './vpnAnimationPolicy';

export function useVpnConnectionAnimations(connectionPhase: ConnectionPhase) {
  const pulseProgress = useRef(new Animated.Value(0)).current;
  const spinProgress = useRef(new Animated.Value(0)).current;
  const animationsEnabled = vpnConnectionAnimationsEnabled(Platform.OS, isTauriRuntime());

  useEffect(() => {
    pulseProgress.stopAnimation();
    pulseProgress.setValue(0);

    if (connectionPhase === 'idle' || !animationsEnabled) {
      return undefined;
    }

    if (connectionPhase === 'connected') {
      // Keep the connected state visually active without forcing a perpetual GPU pulse.
      pulseProgress.setValue(0.35);
      return undefined;
    }

    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulseProgress, {
          duration: 700,
          easing: Easing.inOut(Easing.quad),
          toValue: 1,
          useNativeDriver: true,
        }),
        Animated.timing(pulseProgress, {
          duration: 700,
          easing: Easing.inOut(Easing.quad),
          toValue: 0,
          useNativeDriver: true,
        }),
      ]),
    );
    loop.start();

    return () => loop.stop();
  }, [animationsEnabled, connectionPhase, pulseProgress]);

  useEffect(() => {
    spinProgress.stopAnimation();
    spinProgress.setValue(0);

    if (!animationsEnabled || (connectionPhase !== 'connecting' && connectionPhase !== 'verifying' && connectionPhase !== 'disconnecting' && connectionPhase !== 'switching')) {
      return undefined;
    }

    const loop = Animated.loop(
      Animated.timing(spinProgress, {
        duration: connectionPhase === 'disconnecting' ? 800 : 1100,
        easing: Easing.linear,
        toValue: 1,
        useNativeDriver: true,
      }),
    );
    loop.start();

    return () => loop.stop();
  }, [animationsEnabled, connectionPhase, spinProgress]);

  return { pulseProgress, spinProgress };
}
