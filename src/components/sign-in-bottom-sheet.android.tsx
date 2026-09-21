import {
  ModalBottomSheet,
  type ModalBottomSheetRef,
} from '@expo/ui/jetpack-compose';
import { useEffect, useRef, useState } from 'react';

import type { SignInBottomSheetProps } from './sign-in-bottom-sheet';

export function SignInBottomSheet({ children, isPresented, onDismiss }: SignInBottomSheetProps) {
  const sheetRef = useRef<ModalBottomSheetRef>(null);
  const [isMounted, setIsMounted] = useState(isPresented);

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
    >
      {children}
    </ModalBottomSheet>
  );
}
