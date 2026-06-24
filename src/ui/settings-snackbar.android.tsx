import {
  Box,
  Host,
  Snackbar,
  SnackbarHost,
  type SnackbarHostRef,
} from '@expo/ui/jetpack-compose';
import { align, fillMaxSize, fillMaxWidth } from '@expo/ui/jetpack-compose/modifiers';
import React, { forwardRef, useImperativeHandle, useRef } from 'react';
import { StyleSheet } from 'react-native';
import type { ToastOptions } from '@/ui/toast';

export type SettingsSnackbarRef = {
  showToast: (options: ToastOptions) => void;
};

export const SettingsSnackbar = forwardRef<SettingsSnackbarRef>(function SettingsSnackbar(_props, ref) {
  const snackbarRef = useRef<SnackbarHostRef>(null);

  useImperativeHandle(ref, () => ({
    showToast: (options: ToastOptions) => {
      snackbarRef.current?.showSnackbar({
        actionLabel: options.actionLabel,
        duration: options.duration ?? 'short',
        message: options.message,
        withDismissAction: options.variant === 'error' || options.variant === 'warning',
      }).catch(() => undefined);
    },
  }), []);

  return (
    <Host
      colorScheme="dark"
      pointerEvents="box-none"
      seedColor="#22D3EE"
      style={styles.host}
    >
      <Box modifiers={[fillMaxSize()]}>
        <Box modifiers={[align('bottomCenter'), fillMaxWidth()]}>
          <SnackbarHost ref={snackbarRef}>
            <Snackbar
              actionContentColor="#22D3EE"
              containerColor="#102326"
              contentColor="#F4FCFD"
              dismissActionContentColor="#A7B9BD"
            />
          </SnackbarHost>
        </Box>
      </Box>
    </Host>
  );
});

const styles = StyleSheet.create({
  host: {
    bottom: 0,
    height: 120,
    left: 0,
    position: 'absolute',
    right: 0,
  },
});
