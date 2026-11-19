import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const settings = readFileSync(new URL('../src/screens/settings-screen.tsx', import.meta.url), 'utf8');
const settingsHook = readFileSync(new URL('../src/screens/useVexSettings.ts', import.meta.url), 'utf8');
const appList = readFileSync(new URL('../src/components/universal-vpn-applications-content.tsx', import.meta.url), 'utf8');

// Do not advertise English until the app has translations beyond a saved preference.
assert.match(settings, /<Text numberOfLines=\{1\} style=\{styles.rowDescription\}>\s*Русский\s*<\/Text>/);
assert.doesNotMatch(settings, /SettingsLanguagePicker|settings-language-picker/);
assert.doesNotMatch(settingsHook, /handleLanguagePress|languageKey/);

// The toggle must describe the selected routing mode, not promise a universal
// Russian-service bypass on Android's route-limited profile.
assert.match(settings, /const smartRoutingHint = transport === 'auto' && supportsVless\s*\? '[^']+'\s*: transport === 'vless'/);
assert.match(settings, /Часть российских IP — без VPN\./);
assert.match(settings, /Весь трафик через VPN\./);
assert.match(settings, /Переподключите VPN для применения/);
assert.doesNotMatch(settings, /Российские сервисы без VPN/);

// The app-routing screen has one heading, leaving room for the actual controls.
assert.equal((appList.match(/>Приложения через VPN<\//g) ?? []).length, 1);
assert.match(appList, /Выберите приложения для VPN\./);
console.log('SETTINGS_LANGUAGE_AND_APP_LIST_CONTRACT=PASS');
