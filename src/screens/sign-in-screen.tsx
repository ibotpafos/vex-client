import { useQueryClient } from "@tanstack/react-query";
import * as WebBrowser from "expo-web-browser";
import { router } from "expo-router";
import { StatusBar } from "expo-status-bar";
import {
  Image,
  KeyboardAvoidingView,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import React, { useCallback, useState, useEffect, useRef } from "react";
import { login, exchangeAppAuthCode, vexApiBaseUrl } from "@/api/vexApi";
import { useSession } from "@/auth/session-context";
import { loadSession } from "@/auth/sessionStore";
import { loadSessionWithRetry, loadWithRetry } from "@/auth/sessionLoadRetry";
import {
  authenticateWithBiometrics,
  getBiometricAuthAvailability,
} from "@/native/biometricAuth";
import { getOrCreateDeviceId } from "@/native/appInfo";
import { isTauriRuntime } from "@/native/tauriPlatform";
import {
  playErrorHaptic,
  playLightImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
  playWarningHaptic,
} from "@/native/haptics";
import { VexNativeActivityIndicator } from "@/ui/native-activity-indicator";
import { vexColors, VexScreen, vexSharedStyles } from "@/ui/vex-ui";
import { resetVpnProfileCache } from "@/vpn/profile";
import * as SecureStore from "@/native/secureStore";
import { generateRandomString, generateChallenge } from "@/auth/pkce";
import { buildAppWebAuthUrl } from "@/auth/webAuthUrl";
import {
  openWebAuthUrl,
  supportsWebsiteAuth,
  getDeviceDetails,
  parseQueryString,
  isAppAuthCallbackUrl,
  useKeyboardVisible,
} from "@/auth/systemAuth";

const vexLogo = require("../../assets/vex-logo-header.png");

WebBrowser.maybeCompleteAuthSession();

export default function SignInScreen() {
  const queryClient = useQueryClient();
  const { loadError, signIn } = useSession();
  const isKeyboardVisible = useKeyboardVisible();
  const [authMode, setAuthMode] = useState<"login" | "register">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [authError, setAuthError] = useState<string | null>(null);
  const [isAuthBusy, setIsAuthBusy] = useState(false);
  const [biometricAuthLabel, setBiometricAuthLabel] = useState("");
  const handledCallbackUrls = useRef(new Set<string>());
  const retryableCallbackUrls = useRef<Record<string, number>>({});
  const canUseBiometricAuth =
    authMode === "login" && Boolean(biometricAuthLabel);

  useEffect(() => {
    if (loadError && !authError) {
      setAuthError(loadError);
    }
  }, [authError, loadError]);

  const handleCallbackUrl = useCallback(
    async (url: string) => {
      if (!url) return;
      if (handledCallbackUrls.current.has(url)) return;
      handledCallbackUrls.current.add(url);

      console.log("Received callback URL:", url);
      playLightImpactHaptic();
      setIsAuthBusy(true);
      setAuthError(null);

      try {
        const params = parseQueryString(url);
        const code = params["code"];
        const state = params["state"];

        if (!code || !state) {
          throw new Error("Неверные параметры авторизации от сервера.");
        }

        const savedState = await loadWithRetry(() =>
          SecureStore.getItemAsync("vex.auth.pkce.state"),
        );
        if (!savedState || state !== savedState) {
          throw new Error(
            "Несовпадение параметров безопасности (state mismatch).",
          );
        }

        const verifier = await loadWithRetry(() =>
          SecureStore.getItemAsync("vex.auth.pkce.verifier"),
        );
        if (!verifier) {
          throw new Error("Отсутствует сессия PKCE verifier.");
        }

        const sessionData = await exchangeAppAuthCode(code, verifier);

        resetVpnProfileCache();
        await signIn(sessionData);

        await SecureStore.deleteItemAsync("vex.auth.pkce.state");
        await SecureStore.deleteItemAsync("vex.auth.pkce.verifier");

        await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
        await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
        playSuccessHaptic();
        router.replace("/");
      } catch (err) {
        console.error("Failed to handle callback URL:", err);
        playErrorHaptic();
        setAuthError(
          err instanceof Error ? err.message : "Не удалось завершить вход.",
        );
        const now = Date.now();
        if (now - (retryableCallbackUrls.current[url] ?? 0) > 5_000) {
          retryableCallbackUrls.current[url] = now;
          handledCallbackUrls.current.delete(url);
        }
      } finally {
        setIsAuthBusy(false);
      }
    },
    [queryClient, signIn],
  );

  const handleCallbackUrls = useCallback(
    (urls: string[] | null | undefined) => {
      const callbackUrl = urls?.find(isAppAuthCallbackUrl);
      if (callbackUrl) {
        handleCallbackUrl(callbackUrl);
      }
    },
    [handleCallbackUrl],
  );

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    async function initDeepLink() {
      if (disposed) {
        return;
      }
      if (Platform.OS === "android" || Platform.OS === "ios") {
        const initialUrl = await Linking.getInitialURL();
        if (disposed) {
          return;
        }
        handleCallbackUrls(initialUrl ? [initialUrl] : []);
        const subscription = Linking.addEventListener("url", ({ url }) => {
          handleCallbackUrls([url]);
        });
        unlisten = () => subscription.remove();
        return;
      }

      if (!isTauriRuntime()) return;

      try {
        const [{ onOpenUrl, getCurrent }, { invoke }] = await Promise.all([
          import("@tauri-apps/plugin-deep-link"),
          import("@tauri-apps/api/core"),
        ]);

        const readPendingUrls = async () => {
          if (disposed) {
            return;
          }
          const [currentUrls, pendingUrls] = await Promise.all([
            getCurrent().catch(() => [] as string[]),
            invoke<string[]>("take_pending_deep_links").catch(() => []),
          ]);
          if (disposed) {
            return;
          }
          handleCallbackUrls([...(currentUrls || []), ...pendingUrls]);
        };

        await readPendingUrls();
        if (disposed) {
          return;
        }

        unlisten = await onOpenUrl((urls) => {
          handleCallbackUrls(urls);
        });
        if (disposed) {
          unlisten();
          return;
        }

        const pollId = window.setInterval(readPendingUrls, 1000);
        const previousUnlisten = unlisten;
        unlisten = () => {
          window.clearInterval(pollId);
          previousUnlisten();
        };
      } catch (err) {
        console.error("Failed to initialize deep link listener:", err);
      }
    }

    initDeepLink();

    return () => {
      disposed = true;
      if (unlisten) {
        unlisten();
      }
    };
  }, [handleCallbackUrls]);

  useEffect(() => {
    let mounted = true;

    async function loadBiometricAuthState() {
      const [storedSession, availability] = await Promise.all([
        loadSessionWithRetry(loadSession),
        getBiometricAuthAvailability(),
      ]);

      if (mounted && storedSession && availability.isAvailable) {
        setBiometricAuthLabel(availability.label);
      }
    }

    loadBiometricAuthState().catch(() => undefined);

    return () => {
      mounted = false;
    };
  }, []);

  const handleWebAuthStart = useCallback(async () => {
    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);

    try {
      const verifier = generateRandomString(64);
      const challenge = await generateChallenge(verifier);
      const state = generateRandomString(16);

      await SecureStore.setItemAsync("vex.auth.pkce.verifier", verifier);
      await SecureStore.setItemAsync("vex.auth.pkce.state", state);

      const deviceId = await getOrCreateDeviceId();
      const { platform, deviceName } = getDeviceDetails();

      const webAuthUrl = buildAppWebAuthUrl({
        baseUrl: vexApiBaseUrl,
        challenge,
        deviceId,
        deviceName,
        platform,
        state,
      });

      console.log("Opening Web Auth URL for platform:", platform);
      const callbackUrl = await openWebAuthUrl(webAuthUrl);
      if (isAppAuthCallbackUrl(callbackUrl)) {
        await handleCallbackUrl(callbackUrl);
      }
    } catch (err) {
      console.error("Failed to start web auth:", err);
      playErrorHaptic();
      setAuthError(
        err instanceof Error
          ? err.message
          : "Не удалось запустить веб-авторизацию.",
      );
    } finally {
      setIsAuthBusy(false);
    }
  }, [handleCallbackUrl]);

  const handleAuthSubmit = useCallback(async () => {
    if (isAuthBusy) {
      playWarningHaptic();
      return;
    }
    if (authMode === "register") {
      await handleWebAuthStart();
      return;
    }
    if (!email.trim() || !password) {
      playWarningHaptic();
      setAuthError("Введите email и пароль.");
      return;
    }

    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);
    try {
      const nextSession = await login(email.trim(), password);
      resetVpnProfileCache();
      await signIn(nextSession);
      setPassword("");
      await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
      await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
      playSuccessHaptic();
      router.replace("/");
    } catch (error) {
      playErrorHaptic();
      setAuthError(
        error instanceof Error ? error.message : "Не удалось войти.",
      );
    } finally {
      setIsAuthBusy(false);
    }
  }, [
    authMode,
    email,
    handleWebAuthStart,
    isAuthBusy,
    password,
    queryClient,
    signIn,
  ]);

  const handleBiometricAuth = useCallback(async () => {
    if (isAuthBusy) {
      playWarningHaptic();
      return;
    }

    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);

    try {
      const storedSession = await loadSessionWithRetry(loadSession);
      if (!storedSession) {
        setBiometricAuthLabel("");
        throw new Error(
          "Сохраненная сессия не найдена. Войдите по email и паролю.",
        );
      }

      if (!(await authenticateWithBiometrics())) {
        throw new Error("Биометрическая проверка не подтверждена.");
      }

      resetVpnProfileCache();
      await signIn(storedSession);
      await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
      await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
      playSuccessHaptic();
      router.replace("/");
    } catch (error) {
      playErrorHaptic();
      setAuthError(
        error instanceof Error
          ? error.message
          : "Не удалось войти по биометрии.",
      );
    } finally {
      setIsAuthBusy(false);
    }
  }, [isAuthBusy, queryClient, signIn]);

  return (
    <VexScreen contentStyle={styles.shell}>
      <StatusBar style="light" />
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={styles.keyboardLayer}
      >
        <ScrollView
          bounces={false}
          contentContainerStyle={[
            styles.scrollContent,
            isKeyboardVisible && styles.scrollContentWithKeyboard,
          ]}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
          style={styles.formScroll}
        >
          <View
            style={[
              styles.authPanel,
              isKeyboardVisible && styles.authPanelWithKeyboard,
            ]}
          >
            {isKeyboardVisible ? null : (
              <View style={styles.authIcon}>
                <Image
                  source={vexLogo}
                  resizeMode="contain"
                  style={styles.authLogo as any}
                />
              </View>
            )}
            <Text
              maxFontSizeMultiplier={1.15}
              style={[
                styles.authTitle,
                isKeyboardVisible && styles.authTitleWithKeyboard,
              ]}
            >
              {authMode === "login" ? "Вход в VEX" : "Регистрация"}
            </Text>
            {isKeyboardVisible ? null : (
              <Text maxFontSizeMultiplier={1.05} style={styles.authSubtitle}>
                Проверка доступа и VPN-профиля.
              </Text>
            )}
            <View style={styles.modeSegment}>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ selected: authMode === "login" }}
                onPress={() => {
                  playSelectionHaptic();
                  setAuthError(null);
                  setAuthMode("login");
                }}
                style={[
                  styles.modeSegmentButton,
                  authMode === "login" && styles.modeSegmentButtonActive,
                ]}
              >
                <Text
                  maxFontSizeMultiplier={1.1}
                  style={[
                    styles.modeSegmentText,
                    authMode === "login" && styles.modeSegmentTextActive,
                  ]}
                >
                  Вход
                </Text>
              </Pressable>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ selected: authMode === "register" }}
                onPress={() => {
                  playSelectionHaptic();
                  setAuthError(null);
                  setAuthMode("register");
                }}
                style={[
                  styles.modeSegmentButton,
                  authMode === "register" && styles.modeSegmentButtonActive,
                ]}
              >
                <Text
                  maxFontSizeMultiplier={1.1}
                  style={[
                    styles.modeSegmentText,
                    authMode === "register" && styles.modeSegmentTextActive,
                  ]}
                >
                  Регистрация
                </Text>
              </Pressable>
            </View>
            <TextInput
              autoCapitalize="none"
              autoComplete="off"
              importantForAutofill="no"
              keyboardType="email-address"
              maxFontSizeMultiplier={1.05}
              onChangeText={setEmail}
              onFocus={playSelectionHaptic}
              placeholder="Email"
              placeholderTextColor="#60767B"
              style={styles.input}
              textContentType="none"
              value={email}
            />
            <TextInput
              autoComplete="off"
              autoCapitalize="none"
              importantForAutofill="no"
              maxFontSizeMultiplier={1.05}
              onChangeText={setPassword}
              onFocus={playSelectionHaptic}
              placeholder="Пароль"
              placeholderTextColor="#60767B"
              secureTextEntry
              style={styles.input}
              textContentType="none"
              value={password}
            />
            {authError ? (
              <Text
                maxFontSizeMultiplier={1.15}
                selectable
                style={styles.authError}
              >
                {authError}
              </Text>
            ) : null}
            <Pressable
              disabled={isAuthBusy}
              onPress={handleAuthSubmit}
              style={[styles.primaryButton, isAuthBusy && styles.busy]}
            >
              {isAuthBusy ? (
                <VexNativeActivityIndicator color="#031012" />
              ) : (
                <Text
                  maxFontSizeMultiplier={1.1}
                  style={styles.primaryButtonText}
                >
                  {authMode === "login" ? "Войти" : "Создать аккаунт"}
                </Text>
              )}
            </Pressable>
            {canUseBiometricAuth ? (
              <Pressable
                disabled={isAuthBusy}
                onPress={handleBiometricAuth}
                style={[styles.secondaryButton, isAuthBusy && styles.busy]}
              >
                {isAuthBusy ? (
                  <VexNativeActivityIndicator color="#22D3EE" />
                ) : (
                  <Text
                    maxFontSizeMultiplier={1.1}
                    style={styles.secondaryButtonText}
                  >
                    Войти по {biometricAuthLabel}
                  </Text>
                )}
              </Pressable>
            ) : null}
            {supportsWebsiteAuth() ? (
              <Pressable
                disabled={isAuthBusy}
                onPress={handleWebAuthStart}
                style={[styles.secondaryButton, isAuthBusy && styles.busy]}
              >
                {isAuthBusy ? (
                  <VexNativeActivityIndicator color="#22D3EE" />
                ) : (
                  <Text
                    maxFontSizeMultiplier={1.1}
                    style={styles.secondaryButtonText}
                  >
                    Войти через сайт
                  </Text>
                )}
              </Pressable>
            ) : null}
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </VexScreen>
  );
}

const styles = StyleSheet.create({
  shell: {
    justifyContent: "center",
  },
  keyboardLayer: {
    flex: 1,
    width: "100%",
  },
  formScroll: {
    flex: 1,
    width: "100%",
  },
  scrollContent: {
    flexGrow: 1,
    justifyContent: "center",
    paddingBottom: 12,
    paddingTop: 8,
  },
  scrollContentWithKeyboard: {
    justifyContent: "flex-start",
    paddingBottom: 12,
    paddingTop: 4,
  },
  authPanel: {
    alignItems: "stretch",
    gap: 8,
    paddingHorizontal: 4,
    paddingVertical: 8,
  },
  authPanelWithKeyboard: {
    gap: 7,
    paddingHorizontal: 4,
    paddingVertical: 6,
  },
  authIcon: {
    alignItems: "center",
    alignSelf: "center",
    height: 44,
    justifyContent: "center",
    width: 44,
  },
  authLogo: {
    height: 42,
    width: 42,
  },
  authTitle: {
    color: vexColors.text,
    fontSize: 18,
    fontWeight: "900",
    textAlign: "center",
  },
  authTitleWithKeyboard: {
    fontSize: 16,
  },
  authSubtitle: {
    color: vexColors.muted,
    fontSize: 11,
    lineHeight: 14,
    textAlign: "center",
  },
  modeSegment: {
    backgroundColor: vexColors.field,
    borderColor: "rgba(96,118,123,0.28)",
    borderRadius: 12,
    borderWidth: 1,
    flexDirection: "row",
    gap: 4,
    padding: 4,
  },
  modeSegmentButton: {
    alignItems: "center",
    borderRadius: 10,
    flex: 1,
    justifyContent: "center",
    minHeight: 30,
  },
  modeSegmentButtonActive: {
    backgroundColor: vexColors.accent,
  },
  modeSegmentText: {
    color: vexColors.muted,
    fontSize: 12,
    fontWeight: "900",
  },
  modeSegmentTextActive: {
    color: "#031012",
  },
  input: {
    backgroundColor: vexColors.field,
    borderColor: vexColors.lineStrong,
    borderRadius: 12,
    borderWidth: 1,
    color: vexColors.text,
    fontSize: 14,
    minHeight: 42,
    paddingHorizontal: 10,
  },
  authError: {
    color: vexColors.danger,
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 16,
    textAlign: "center",
  },
  primaryButton: {
    ...vexSharedStyles.primaryButton,
    borderRadius: 12,
    minHeight: 44,
  },
  primaryButtonText: {
    ...vexSharedStyles.primaryButtonText,
    fontSize: 14,
  },
  busy: {
    ...vexSharedStyles.busy,
  },
  secondaryButton: {
    alignItems: "center",
    backgroundColor: "transparent",
    borderColor: vexColors.accent,
    borderRadius: 12,
    borderWidth: 1,
    justifyContent: "center",
    minHeight: 42,
  },
  secondaryButtonText: {
    color: vexColors.accent,
    fontSize: 14,
    fontWeight: "900",
  },
});
