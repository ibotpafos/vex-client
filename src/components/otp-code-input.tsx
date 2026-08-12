import { forwardRef, useImperativeHandle, useRef } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { emailOTPCells, normalizeEmailOTPCode } from '@/auth/emailOtp';
import { vexColors } from '@/ui/vex-ui';

const defaultLength = 6;

export type OTPCodeInputHandle = {
  focus: () => void;
};

type OTPCodeInputProps = {
  value: string;
  onChangeText: (value: string) => void;
  disabled?: boolean;
  length?: number;
};

export const OTPCodeInput = forwardRef<OTPCodeInputHandle, OTPCodeInputProps>(function OTPCodeInput(
  { value, onChangeText, disabled = false, length = defaultLength },
  ref,
) {
  const inputRef = useRef<TextInput>(null);
  const digits = emailOTPCells(value, length);

  useImperativeHandle(ref, () => ({
    focus: () => inputRef.current?.focus(),
  }));

  return (
    <View style={styles.root}>
      <Pressable
        accessibilityHint="Откроет цифровую клавиатуру для ввода кода из письма"
        accessibilityLabel={`Код из письма, введено ${value.length} из ${length} цифр`}
        accessibilityRole="button"
        disabled={disabled}
        onPress={() => inputRef.current?.focus()}
        style={styles.cells}
      >
        {digits.map((digit, index) => (
          <View
            key={index}
            style={[styles.cell, digit && styles.cellFilled, disabled && styles.cellDisabled]}
          >
            <Text maxFontSizeMultiplier={1} style={styles.digit}>
              {digit}
            </Text>
          </View>
        ))}
      </Pressable>
      <TextInput
        ref={inputRef}
        accessibilityElementsHidden
        autoCapitalize="none"
        autoComplete="one-time-code"
        importantForAutofill="yes"
        keyboardType="number-pad"
        maxLength={length}
        onChangeText={(nextValue) => onChangeText(normalizeEmailOTPCode(nextValue))}
        style={styles.hiddenInput}
        textContentType="oneTimeCode"
        value={value}
      />
    </View>
  );
});

const styles = StyleSheet.create({
  root: {
    minHeight: 58,
    position: 'relative',
    width: '100%',
  },
  cells: {
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'space-between',
  },
  cell: {
    alignItems: 'center',
    backgroundColor: vexColors.field,
    borderColor: vexColors.lineStrong,
    borderCurve: 'continuous',
    borderRadius: 14,
    borderWidth: 1,
    flex: 1,
    justifyContent: 'center',
    minHeight: 58,
  },
  cellFilled: {
    borderColor: vexColors.accent,
  },
  cellDisabled: {
    opacity: 0.55,
  },
  digit: {
    color: vexColors.text,
    fontSize: 22,
    fontVariant: ['tabular-nums'],
    fontWeight: '800',
  },
  hiddenInput: {
    height: 1,
    left: 0,
    opacity: 0.01,
    position: 'absolute',
    top: 0,
    width: 1,
  },
});
