import { vexTheme } from '@/ui/vex-theme';
import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { Modal, Pressable, StyleSheet, Text, View } from 'react-native';

export type ToastVariant = 'info' | 'success' | 'warning' | 'error';

export type ToastOptions = {
  message: string;
  variant?: ToastVariant;
  actionLabel?: string;
  duration?: 'short' | 'long';
};

type ToastContextValue = {
  showToast: (options: ToastOptions) => void;
};

const ToastContext = createContext<ToastContextValue | null>(null);

let toastId = 0;

export function ToastProvider({ children }: { children: ReactNode }) {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [toast, setToast] = useState<(ToastOptions & { id: number }) | null>(null);

  const hideToast = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    setToast(null);
  }, []);

  const showToast = useCallback((options: ToastOptions) => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
    }
    const id = ++toastId;
    setToast({ id, ...options });
    timerRef.current = setTimeout(
      () => setToast((current) => (current?.id === id ? null : current)),
      options.duration === 'long' ? 4200 : 2600,
    );
  }, []);

  const contextValue = useMemo(() => ({ showToast }), [showToast]);

  return (
    <ToastContext.Provider value={contextValue}>
      <View style={styles.root}>
        {children}
        <Modal
          animationType="fade"
          onRequestClose={hideToast}
          statusBarTranslucent
          transparent
          visible={Boolean(toast)}
        >
          <View pointerEvents="box-none" style={styles.modalRoot}>
            {toast ? (
              <Pressable
                accessibilityRole="button"
                onPress={hideToast}
                style={[styles.toast, styles[`toast_${toast.variant ?? 'info'}`]]}
              >
                <Text style={styles.toastText}>{toast.message}</Text>
              </Pressable>
            ) : null}
          </View>
        </Modal>
      </View>
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used inside ToastProvider');
  }
  return context;
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  modalRoot: {
    flex: 1,
    justifyContent: 'flex-end',
    pointerEvents: 'box-none',
  },
  toast: {
    alignSelf: 'center',
    minHeight: 44,
    justifyContent: 'center',
    borderRadius: 16,
    borderWidth: 1,
    marginBottom: 28,
    maxWidth: '90%',
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  toast_info: {
    backgroundColor: vexTheme.colors.surfaceRaised,
    borderColor: vexTheme.colors.line,
  },
  toast_success: {
    backgroundColor: vexTheme.colors.surfaceRaised,
    borderColor: vexTheme.colors.success,
  },
  toast_warning: {
    backgroundColor: vexTheme.colors.surfaceRaised,
    borderColor: vexTheme.colors.warning,
  },
  toast_error: {
    backgroundColor: vexTheme.colors.surfaceRaised,
    borderColor: vexTheme.colors.danger,
  },
  toastText: {
    color: vexTheme.colors.text,
    fontSize: 14,
    fontWeight: '600',
    lineHeight: 20,
    textAlign: 'center',
  },
});
