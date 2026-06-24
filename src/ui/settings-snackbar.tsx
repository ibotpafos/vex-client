import { forwardRef, useImperativeHandle } from 'react';
import type { ToastOptions } from '@/ui/toast';

export type SettingsSnackbarRef = {
  showToast: (options: ToastOptions) => void;
};

export const SettingsSnackbar = forwardRef<SettingsSnackbarRef>(function SettingsSnackbar(_props, ref) {
  useImperativeHandle(ref, () => ({ showToast: () => undefined }), []);
  return null;
});
