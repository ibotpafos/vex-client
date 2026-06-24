import React, {
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
    borderRadius: 18,
    borderWidth: 1,
    marginBottom: 28,
    maxWidth: '90%',
    paddingHorizontal: 16,
    paddingVertical: 12,
    shadowColor: '#000',
    shadowOffset: { height: 8, width: 0 },
    shadowOpacity: 0.3,
    shadowRadius: 18,
  },
  toast_info: {
    backgroundColor: '#102326',
    borderColor: 'rgba(34,211,238,0.28)',
  },
  toast_success: {
    backgroundColor: '#0F2A20',
    borderColor: 'rgba(75,232,166,0.34)',
  },
  toast_warning: {
    backgroundColor: '#2C2412',
    borderColor: 'rgba(255,211,106,0.4)',
  },
  toast_error: {
    backgroundColor: '#2B1518',
    borderColor: 'rgba(255,159,159,0.42)',
  },
  toastText: {
    color: '#F4FCFD',
    fontSize: 14,
    fontWeight: '800',
    lineHeight: 19,
    textAlign: 'center',
  },
});
