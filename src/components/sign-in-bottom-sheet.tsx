import { BottomSheet } from '@expo/ui';
import type { ReactNode } from 'react';

export type SignInBottomSheetProps = {
  children: ReactNode;
  isPresented: boolean;
  onDismiss: () => void;
};

export function SignInBottomSheet({ children, isPresented, onDismiss }: SignInBottomSheetProps) {
  return (
    <BottomSheet
      isPresented={isPresented}
      onDismiss={onDismiss}
      snapPoints={['full']}
      testID="sign-in-sheet"
    >
      {children}
    </BottomSheet>
  );
}
