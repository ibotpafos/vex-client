const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const ts = require('typescript');

const root = process.env.VEX_UNSLOP_SOURCE_ROOT || path.resolve(__dirname, '..');
function load(file) {
  const absolute = path.join(root, file);
  const module = { exports: {} };
  const native = {
    Animated: { View: 'AnimatedView' }, ImageBackground: 'ImageBackground', Platform: { OS: 'android' },
    StyleSheet: { create: styles => styles, hairlineWidth: 0.5 },
    Text: 'Text', View: 'View', Pressable: 'Pressable', useWindowDimensions: () => ({ width: 360 }),
  };
  const boundaries = {
    'react-native': native, react: require('react'), 'react/jsx-runtime': require('react/jsx-runtime'),
    'lucide-react-native': Object.fromEntries(['ChevronRight', 'MapPin', 'Globe', 'Power', 'Settings', 'Shield'].map(name => [name, name])),
    'react-native-safe-area-context': { useSafeAreaInsets: () => ({ top: 24, bottom: 0 }), SafeAreaView: 'SafeAreaView' },
    '@/components/vex-wordmark': { VexWordmark: 'VexWordmark' },
  };
  const compiled = ts.transpileModule(fs.readFileSync(absolute, 'utf8'), {
    fileName: absolute, compilerOptions: { module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true },
  }).outputText;
  new Function('require', 'module', 'exports', compiled)(id => {
    if (Object.hasOwn(boundaries, id)) return boundaries[id];
    if (id.endsWith('.png')) return 'fixture-city-image';
    const next = id.startsWith('@/') ? path.join(root, 'src', id.slice(2))
      : id.startsWith('.') ? path.resolve(path.dirname(absolute), id) : null;
    assert.ok(next, `Unexpected dependency ${id}`);
    const source = ['.ts', '.tsx'].map(extension => next + extension).find(fs.existsSync);
    assert.ok(source, `Missing dependency ${id}`);
    return load(path.relative(root, source));
  }, module, module.exports);
  return module.exports;
}

function nodes(tree) {
  if (!tree || typeof tree !== 'object') return [];
  return [tree, ...[tree.props?.children].flat(Infinity).flatMap(nodes)];
}
function render(overrides = {}) {
  return load('src/components/location-home-hero.tsx').LocationHomeHero({
    connectionPhase: 'idle', latencyText: '18 мс', selectionMode: 'auto', protocolLabel: 'AWG',
    location: { id: 'de', countryCode: 'DE', city: 'Frankfurt', flagEmoji: '🇩🇪' },
    onPowerPress() {}, onLocationPress() {}, onSettingsPress() {}, powerButtonDisabled: false,
    pulseProgress: { interpolate: () => 1 }, ...overrides,
  });
}

test('idle copy states that VPN is off rather than claiming a protected connection', () => {
  const { homeConnectionPresentation } = load('src/screens/home-screen-visual.ts');
  assert.equal(homeConnectionPresentation('idle').helper, 'VPN выключен');
  assert.equal(homeConnectionPresentation('connected').helper, 'Соединение защищено');
  for (const phase of ['connecting', 'verifying', 'switching', 'disconnecting']) {
    assert.equal(homeConnectionPresentation(phase).tone, 'busy');
    assert.doesNotMatch(homeConnectionPresentation(phase).helper, /Соединение защищено|VPN выключен/);
  }
});

test('home preserves the three native actions and chosen protocol semantics', () => {
  const calls = [];
  const tree = render({ onPowerPress: () => calls.push('power'), onSettingsPress: () => calls.push('settings'),
    onLocationPress: () => calls.push('location') });
  const buttons = nodes(tree).filter(node => node.props?.accessibilityRole === 'button');
  assert.equal(buttons.length, 3);
  const location = buttons.find(node => node.props.title === 'Выбрать локацию');
  assert.match(location.props.accessibilityLabel, /Выбранный протокол: AWG/);
  buttons.forEach(button => button.props.onPress());
  assert.deepEqual(calls, ['settings', 'power', 'location']);
  assert.equal(nodes(tree).find(node => node.props?.testID === 'home-selected-protocol').props.children, 'AWG');
});

test('server country and measured latency survive replacement of emoji decoration', () => {
  const tree = render();
  const text = nodes(tree).filter(node => node.type === 'Text').map(node => node.props.children).flat().join(' ');
  assert.match(text, /Германия/);
  assert.match(text, /18 мс/);
  assert.doesNotMatch(text, /🇩🇪|🌐/u);
});

test('pending and disabled power states remain accessible after the visual change', () => {
  for (const connectionPhase of ['connecting', 'verifying']) {
    const button = nodes(render({ connectionPhase, powerButtonDisabled: true }))
      .find(node => node.props?.accessibilityState?.busy);
    assert.ok(button);
    assert.equal(button.props.disabled, true);
    assert.equal(button.props.accessibilityState.disabled, true);
  }
});

test('shared icon controls retain at least a 44dp touch area', () => {
  const { vexSharedStyles } = load('src/ui/vex-ui.tsx');
  assert.ok(vexSharedStyles.iconButton.height >= 44);
  assert.ok(vexSharedStyles.iconButton.width >= 44);
});

test('neutral surfaces keep secondary and muted text readable', () => {
  const { colors } = load('src/ui/vex-theme.ts').vexTheme;
  function luminance(hex) {
    const rgb = hex.slice(1).match(/../g).map(channel => parseInt(channel, 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
  }
  for (const foreground of [colors.textSecondary, colors.textMuted]) {
    for (const background of [colors.background, colors.field, colors.surfaceRaised]) {
      assert.ok((luminance(foreground) + 0.05) / (luminance(background) + 0.05) >= 4.5,
        `${foreground} must be readable on ${background}`);
    }
  }
});

test('auth sheet buttons emit a native minimum height without fixing text height', () => {
  const sourcePath = path.join(root, 'src/screens/sign-in-screen.tsx');
  const source = ts.createSourceFile(sourcePath, fs.readFileSync(sourcePath, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const values = {};
  let buttonCount = 0;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && ['sheetButtonStyle', 'sheetButtonModifiers'].includes(node.name.getText(source))) {
      values[node.name.getText(source)] = node.initializer.getText(source);
    }
    if (ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node)) {
      const attributes = node.attributes.properties;
      if (attributes.some(item => ts.isJsxAttribute(item) && item.name.text === 'style'
        && item.initializer?.getText(source) === '{sheetButtonStyle}')) {
        buttonCount++;
        assert.ok(attributes.some(item => ts.isJsxAttribute(item) && item.name.text === 'modifiers'
          && item.initializer?.getText(source) === '{sheetButtonModifiers}'));
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  assert.ok(buttonCount >= 5, 'all auth actions must use the shared native sizing');
  function expoModule(relative) {
    const file = path.join(__dirname, '../node_modules/@expo/ui/src', relative);
    const module = { exports: {} };
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    new Function('require', 'module', 'exports', '__DEV__', code)(id => {
      const next = id === '@expo/ui/jetpack-compose/modifiers' ? 'jetpack-compose/modifiers/index.ts'
        : path.relative(path.join(__dirname, '../node_modules/@expo/ui/src'), path.resolve(path.dirname(file), id)) + '.ts';
      return expoModule(next);
    }, module, module.exports, false);
    return module.exports;
  }
  const { defaultMinSize } = expoModule('jetpack-compose/modifiers/index.ts');
  const evaluate = expression => new Function('Platform', 'width', 'defaultMinSize', `return (${expression});`)({ OS: 'android' }, 320, defaultMinSize);
  const style = evaluate(values.sheetButtonStyle);
  const extras = values.sheetButtonModifiers ? evaluate(values.sheetButtonModifiers) : undefined;
  const modifiers = expoModule('universal/transformStyle.android.ts').transformToModifiers(style, {}, extras);
  assert.ok(modifiers.some(item => item.$type === 'defaultMinSize' && item.minHeight >= 48));
  assert.equal(modifiers.some(item => item.$type === 'height' || item.$type === 'size'), false);
});

test('isolated native settings switches inherit the VEX accent and keep toggle semantics', () => {
  const filename = path.join(root, 'src/screens/settings-screen.tsx');
  const file = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const declaration = file.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === 'SettingsNativeSwitch');
  assert.ok(declaration);
  const compiled = ts.transpileModule(declaration.getText(file), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.React },
  }).outputText;
  const theme = load('src/ui/vex-theme.ts').vexTheme;
  const toggle = () => {};
  const props = { accessibilityLabel: 'fixture switch', disabled: true, onValueChange: toggle, testID: 'fixture-switch', value: true };
  const tree = new Function('React', 'Host', 'ExpoSwitch', 'styles', 'vexTheme', 'props',
    compiled + '; return SettingsNativeSwitch(props);')(require('react'), 'Host', 'ExpoSwitch', {}, theme, props);
  assert.equal(tree.props.seedColor, '#43D9E7');
  assert.deepEqual(tree.props.accessibilityState, { checked: true, disabled: true });
  assert.equal(tree.props.children.props.onValueChange, toggle);
  assert.equal(tree.props.children.props.disabled, true);
});
