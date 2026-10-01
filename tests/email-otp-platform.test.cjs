const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(process.argv[2] || 'src/components/otp-code-input.tsx', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
}).outputText;
const native = fs.readFileSync('node_modules/react-native/ReactAndroid/src/main/java/com/facebook/react/views/textinput/ReactTextInputManager.kt', 'utf8');
for (const platform of ['android', 'ios']) {
  const exports = {};
  const render = (type, props) => ({ type, props });
  const modules = {
    'react/jsx-runtime': { jsx: render, jsxs: render },
    react: { forwardRef: f => f, useImperativeHandle: () => {}, useRef: () => ({ current: null }) },
    'react-native': { Platform: { OS: platform }, View: 'View', Text: 'Text', TextInput: 'TextInput', Pressable: 'Pressable', StyleSheet: { create: x => x } },
    '@/auth/emailOtp': { emailOTPCells: () => Array(6).fill(''), normalizeEmailOTPCode: s => s.replace(/\D/g, '').slice(0, 6) },
    '@/ui/vex-ui': { vexColors: {} },
  };
  vm.runInNewContext(compiled, { exports, require: id => { assert.ok(modules[id], id); return modules[id]; } });
  const tree = exports.OTPCodeInput({ value: '', onChangeText: () => {} }, null);
  const findInput = n => !n || typeof n !== 'object' ? undefined : n.type === 'TextInput' ? n : [n.props?.children].flat().filter(Boolean).map(findInput).find(Boolean);
  const input = findInput(tree).props;
  const expected = platform === 'android' ? 'email-otp' : 'one-time-code';
  assert.equal(input.autoComplete, expected, `${platform} must publish its supported email OTP hint`);
  assert.equal(input.importantForAutofill, 'yes');
  assert.equal(input.maxLength, 6);
  assert.equal(input.keyboardType, 'number-pad');
  if (platform === 'android') assert.ok(native.includes(`"${input.autoComplete}" to HintConstants.AUTOFILL_HINT_EMAIL_OTP`));
  else assert.equal(input.textContentType, 'oneTimeCode');
}
console.log('EMAIL_OTP_PLATFORM_HINTS=PASS');
