import {
  Column,
  ModalBottomSheet,
  type ModalBottomSheetRef,
} from '@expo/ui/jetpack-compose';
import { fillMaxHeight, padding, verticalScroll } from '@expo/ui/jetpack-compose/modifiers';
import { useEffect, useRef, useState } from 'react';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { SignInBottomSheetProps } from './sign-in-bottom-sheet';

export function SignInBottomSheet({ children, isPresented, onDismiss }: SignInBottomSheetProps) {
  const sheetRef = useRef<ModalBottomSheetRef>(null);
  const [isMounted, setIsMounted] = useState(isPresented);
  const insets = useSafeAreaInsets();

  useEffect(() => {
    if (isPresented) {
      setIsMounted(true);
      return;
    }
    sheetRef.current?.hide().finally(() => setIsMounted(false));
  }, [isPresented]);

  if (!isMounted) {
    return null;
  }

  return (
    <ModalBottomSheet
      containerColor="#041315"
      contentColor="#E9F7F8"
      onDismissRequest={() => {
        setIsMounted(false);
        onDismiss();
      }}
      ref={sheetRef}
      sheetGesturesEnabled
      skipPartiallyExpanded
    >
      <Column modifiers={[
        fillMaxHeight(),
        verticalScroll(),
        padding(0, 0, 0, Math.max(20, insets.bottom + 20)),
      ]}>
        {children}
      </Column>
    </ModalBottomSheet>
  );
}
