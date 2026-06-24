import { useEffect, useRef } from 'react';
import { Animated, Easing } from 'react-native';
import { isTauriRuntime, type ConnectionPhase } from '../screens/home-screen-helpers';

export function useVpnConnectionAnimations(connectionPhase: ConnectionPhase) {
  const pulseProgress = useRef(new Animated.Value(0)).current;
  const spinProgress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    pulseProgress.stopAnimation();
    pulseProgress.setValue(0);

    if (connectionPhase === 'idle' || isTauriRuntime()) {
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
  }, [connectionPhase, pulseProgress]);

  useEffect(() => {
    spinProgress.stopAnimation();
    spinProgress.setValue(0);

    if (connectionPhase !== 'connecting' && connectionPhase !== 'verifying' && connectionPhase !== 'disconnecting' && connectionPhase !== 'switching') {
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
  }, [connectionPhase, spinProgress]);

  return { pulseProgress, spinProgress };
}
