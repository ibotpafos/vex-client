import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const settings = readFileSync(new URL('../src/screens/settings-screen.tsx', import.meta.url), 'utf8');
const settingsHook = readFileSync(new URL('../src/screens/useVexSettings.ts', import.meta.url), 'utf8');
const appList = readFileSync(new URL('../src/components/universal-vpn-applications-content.tsx', import.meta.url), 'utf8');

// Do not advertise English until the app has translations beyond a saved preference.
assert.match(settings, /Сейчас доступен только русский интерфейс\./);
assert.doesNotMatch(settings, /SettingsLanguagePicker|settings-language-picker/);
assert.doesNotMatch(settingsHook, /handleLanguagePress|languageKey/);

// The app-routing screen has one heading, leaving room for the actual controls.
assert.equal((appList.match(/>Приложения через VPN<\//g) ?? []).length, 1);
assert.match(appList, /Выберите, какие приложения будут использовать защищённое соединение\./);
console.log('SETTINGS_LANGUAGE_AND_APP_LIST_CONTRACT=PASS');
