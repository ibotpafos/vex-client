import { useQueryClient } from "@tanstack/react-query";
import {
  BottomSheet,
  Button,
  Column,
  Host,
  RNHostView,
  Text as UniversalText,
  TextInput as UniversalTextInput,
} from "@expo/ui";
import {
  ModalBottomSheet,
  type ModalBottomSheetRef,
} from "@expo/ui/jetpack-compose";
import * as WebBrowser from "expo-web-browser";
import { router } from "expo-router";
import {
  Linking,
  Platform,
  useWindowDimensions,
  View,
} from "react-native";
import { useCallback, useState, useEffect, useRef, type ReactNode } from "react";
import {
  requestEmailOTP,
  confirmEmailOTP,
  exchangeAppAuthCode,
  vexApiBaseUrl,
} from "@/api/vexApi";
import { signInWithGoogleAndroid, isGoogleSignInCancelled } from "@/native/googleAuth";
import { useSession } from "@/auth/session-context";
import {
  authCallbackAttemptKey,
  getOrCreateAuthCallbackAttempt,
  resolveAuthCallbackExchange,
  type AuthCallbackAttempt,
} from "@/auth/callbackParams";
import { loadSession } from "@/auth/sessionStore";
import { loadSessionWithRetry, loadWithRetry } from "@/auth/sessionLoadRetry";
import {
  authenticateWithBiometrics,
  getBiometricAuthAvailability,
} from "@/native/biometricAuth";
import { getOrCreateDeviceId } from "@/native/appInfo";
import {
  playErrorHaptic,
  playLightImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
  playWarningHaptic,
} from "@/native/haptics";
import { OTPCodeInput } from "@/components/otp-code-input";
import { UniversalSignInWelcome } from "@/components/universal-sign-in-welcome";
import { resetVpnProfileCache } from "@/vpn/profile";
import * as SecureStore from "@/native/secureStore";
import { generateRandomString, generateChallenge } from "@/auth/pkce";
import { buildAppWebAuthUrl } from "@/auth/webAuthUrl";
import {
  emailOTPRequestErrorMessage,
  isEmailOTPExpired,
  isEmailOTPRequestCooldownError,
  isInvalidOrExpiredEmailOTPError,
  normalizeEmailOTPCode,
} from "@/auth/emailOtp";
import { type AuthEntryStep } from "@/auth/authEntry";
import {
  openWebAuthUrl,
  supportsWebsiteAuth,
  getDeviceDetails,
  parseQueryString,
  isAppAuthCallbackUrl,
} from "@/auth/systemAuth";

WebBrowser.maybeCompleteAuthSession();

type SignInBottomSheetProps = {
  children: ReactNode;
  isPresented: boolean;
  onDismiss: () => void;
};

function SignInBottomSheet({ children, isPresented, onDismiss }: SignInBottomSheetProps) {
  const sheetRef = useRef<ModalBottomSheetRef>(null);
  const [isAndroidSheetMounted, setIsAndroidSheetMounted] = useState(isPresented);

  useEffect(() => {
    if (isPresented) {
      setIsAndroidSheetMounted(true);
      return;
    }
    sheetRef.current?.hide().finally(() => setIsAndroidSheetMounted(false));
  }, [isPresented]);

  if (Platform.OS !== "android") {
    return (
      <BottomSheet
        isPresented={isPresented}
        onDismiss={onDismiss}
        snapPoints={["full"]}
        testID="sign-in-sheet"
      >
        {children}
      </BottomSheet>
    );
  }

  if (!isAndroidSheetMounted) {
    return null;
  }

  return (
    <ModalBottomSheet
      containerColor="#041315"
      contentColor="#E9F7F8"
      onDismissRequest={() => {
        setIsAndroidSheetMounted(false);
        onDismiss();
      }}
      ref={sheetRef}
      sheetGesturesEnabled
    >
      {children}
    </ModalBottomSheet>
  );
}

export default function SignInScreen() {
  const queryClient = useQueryClient();
  const { width } = useWindowDimensions();
  const { loadError, signIn } = useSession();
  const [entryStep, setEntryStep] = useState<AuthEntryStep>("welcome");
  const [email, setEmail] = useState("");
  const [emailOTPCode, setEmailOTPCode] = useState("");
  const [emailOTPChallenge, setEmailOTPChallenge] = useState<{
    email: string;
    challengeId: string;
    expiresAt?: string;
  } | null>(null);
  const [authError, setAuthError] = useState<string | null>(null);
  const [authNotice, setAuthNotice] = useState<string | null>(null);
  const [isAuthBusy, setIsAuthBusy] = useState(false);
  const [biometricAuthLabel, setBiometricAuthLabel] = useState("");
  const authSubmitInFlight = useRef(false);
  const callbackAttemptRef = useRef<AuthCallbackAttempt<void> | null>(null);
  const handledCallbackUrls = useRef(new Set<string>());
  const retryableCallbackUrls = useRef<Record<string, number>>({});
  const canUseBiometricAuth = Boolean(biometricAuthLabel);

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

      console.log("Received auth callback");
      playLightImpactHaptic();
      setIsAuthBusy(true);
      setAuthError(null);

      try {
        const params = parseQueryString(url);
        const code = params["code"];
        const state = params["state"];

        const attemptKey = authCallbackAttemptKey({ code, state });
        const attempt = getOrCreateAuthCallbackAttempt(
          callbackAttemptRef.current,
          attemptKey,
          async () => {
            const [savedState, savedVerifier] = await Promise.all([
              loadWithRetry(() => SecureStore.getItemAsync("vex.auth.pkce.state")),
              loadWithRetry(() => SecureStore.getItemAsync("vex.auth.pkce.verifier")),
            ]);
            const exchange = resolveAuthCallbackExchange(
              { code, state },
              savedState,
              savedVerifier,
            );
            const sessionData = await exchangeAppAuthCode(exchange.code, exchange.verifier);

            resetVpnProfileCache();
            await signIn(sessionData);
            await SecureStore.deleteItemAsync("vex.auth.pkce.state");
            await SecureStore.deleteItemAsync("vex.auth.pkce.verifier");
            await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
            await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
          },
        );
        callbackAttemptRef.current = attempt;
        await attempt.promise;
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

  const handleWebAuthStart = useCallback(async (provider?: "google") => {
    if (authSubmitInFlight.current) return;
    authSubmitInFlight.current = true;
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
        provider,
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
      authSubmitInFlight.current = false;
      setIsAuthBusy(false);
    }
  }, [handleCallbackUrl]);

  const handleGoogleSignIn = useCallback(async () => {
    if (Platform.OS !== "android") {
      await handleWebAuthStart("google");
      return;
    }
    if (authSubmitInFlight.current) return;
    authSubmitInFlight.current = true;
    setIsAuthBusy(true);
    setAuthError(null);
    setAuthNotice(null);
    playLightImpactHaptic();
    try {
      const nextSession = await signInWithGoogleAndroid();
      resetVpnProfileCache();
      await signIn(nextSession);
      setEmailOTPCode("");
      setEmailOTPChallenge(null);
      await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
      await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
      playSuccessHaptic();
      router.replace("/");
    } catch (error) {
      if (!isGoogleSignInCancelled(error)) {
        playErrorHaptic();
        setAuthError("Не удалось войти через Google. Проверьте интернет и повторите вход.");
      }
    } finally {
      authSubmitInFlight.current = false;
      setIsAuthBusy(false);
    }
  }, [handleWebAuthStart, queryClient, signIn]);

  const handleEmailChange = useCallback((value: string) => {
    setEmail(value);
    setEmailOTPCode("");
    setEmailOTPChallenge(null);
    setAuthNotice(null);
  }, []);

  const handleAuthSubmit = useCallback(async () => {
    if (authSubmitInFlight.current || isAuthBusy) {
      playWarningHaptic();
      return;
    }
    const normalizedEmail = email.trim();
    if (!normalizedEmail) {
      playWarningHaptic();
      setAuthError("Введите email.");
      return;
    }

    authSubmitInFlight.current = true;
    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);
    setAuthNotice(null);
    try {
      if (!emailOTPChallenge || emailOTPChallenge.email !== normalizedEmail) {
        const challenge = await requestEmailOTP(normalizedEmail);
        setEmailOTPChallenge({
          email: normalizedEmail,
          challengeId: challenge.challengeId,
          expiresAt: challenge.expiresAt,
        });
        setEmailOTPCode("");
        setAuthNotice("Код отправлен на email.");
        playSuccessHaptic();
        return;
      }
      if (isEmailOTPExpired(emailOTPChallenge.expiresAt)) {
        const challenge = await requestEmailOTP(normalizedEmail);
        setEmailOTPChallenge({
          email: normalizedEmail,
          challengeId: challenge.challengeId,
          expiresAt: challenge.expiresAt,
        });
        setEmailOTPCode("");
        setAuthNotice("Срок прошлого кода истёк. Мы отправили новый.");
        playSuccessHaptic();
        return;
      }
      const code = normalizeEmailOTPCode(emailOTPCode);
      if (code.length !== 6) {
        playWarningHaptic();
        setAuthError("Введите 6 цифр кода из письма.");
        return;
      }
      const nextSession = await confirmEmailOTP(
        normalizedEmail,
        emailOTPChallenge.challengeId,
        code,
      );
      resetVpnProfileCache();
      await signIn(nextSession);
      setEmailOTPCode("");
      setEmailOTPChallenge(null);
      await queryClient.invalidateQueries({ queryKey: ["entitlement"] });
      await queryClient.invalidateQueries({ queryKey: ["vpn-profile"] });
      playSuccessHaptic();
      router.replace("/");
    } catch (error) {
      playErrorHaptic();
      if (isEmailOTPRequestCooldownError(error)) {
        setAuthNotice(emailOTPRequestErrorMessage(error));
        return;
      }
      setAuthError(isInvalidOrExpiredEmailOTPError(error)
        ? "Проверьте код из письма или запросите новый."
        : emailOTPRequestErrorMessage(error));
    } finally {
      authSubmitInFlight.current = false;
      setIsAuthBusy(false);
    }
  }, [
    email,
    emailOTPChallenge,
    emailOTPCode,
    isAuthBusy,
    queryClient,
    signIn,
  ]);

  const handleEmailOTPResend = useCallback(async () => {
    if (authSubmitInFlight.current || isAuthBusy) {
      playWarningHaptic();
      return;
    }
    const normalizedEmail = email.trim();
    if (!normalizedEmail) {
      setAuthError("Введите email.");
      return;
    }
    authSubmitInFlight.current = true;
    setIsAuthBusy(true);
    setAuthError(null);
    setAuthNotice(null);
    try {
      const challenge = await requestEmailOTP(normalizedEmail);
      setEmailOTPChallenge({
        email: normalizedEmail,
        challengeId: challenge.challengeId,
        expiresAt: challenge.expiresAt,
      });
      setEmailOTPCode("");
      setAuthNotice("Новый код отправлен на email.");
      playSuccessHaptic();
    } catch (error) {
      playErrorHaptic();
      if (isEmailOTPRequestCooldownError(error)) {
        setAuthNotice(emailOTPRequestErrorMessage(error));
        return;
      }
      setAuthError(emailOTPRequestErrorMessage(error));
    } finally {
      authSubmitInFlight.current = false;
      setIsAuthBusy(false);
    }
  }, [email, isAuthBusy]);

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
          "Сохраненная сессия не найдена. Войдите по email-коду.",
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

  const sheetTitle = emailOTPChallenge ? "Проверьте почту" : "Войти в VEX";
  const sheetIntro = "Введите email — пришлём одноразовый код для входа.";
  const sheetButtonStyle = { width: Math.max(280, width - 40) };
  const emailContent = (
    <Column spacing={10} style={styles.sheetContent} testID="sign-in-sheet">
      <Column spacing={12}>
        <UniversalText textStyle={styles.sheetTitle}>{sheetTitle}</UniversalText>
        {!emailOTPChallenge ? (
          <UniversalText textStyle={styles.sheetIntro}>{sheetIntro}</UniversalText>
        ) : null}
        {emailOTPChallenge ? (
          <UniversalText textStyle={styles.emailRecipient}>
            {`Код отправлен на ${emailOTPChallenge.email}`}
          </UniversalText>
        ) : (
          <UniversalTextInput
              autoCapitalize="none"
              autoComplete="off"
              keyboardType="email-address"
              onChangeText={handleEmailChange}
              onFocus={playSelectionHaptic}
              placeholder="Email"
              placeholderTextColor="#A7B9BD"
              style={styles.emailInput}
              textStyle={styles.emailInputText}
            />
        )}
        {emailOTPChallenge ? (
          <>
            <RNHostView matchContents>
              <View style={{ width: sheetButtonStyle.width }}>
                <OTPCodeInput disabled={isAuthBusy} onChangeText={setEmailOTPCode} value={emailOTPCode} />
              </View>
            </RNHostView>
          </>
        ) : null}
        {authNotice && authNotice !== "Код отправлен на email." ? (
          <UniversalText textStyle={styles.notice}>{authNotice}</UniversalText>
        ) : null}
        {authError ? <UniversalText textStyle={styles.error}>{authError}</UniversalText> : null}
        <Button
          disabled={isAuthBusy}
          label={isAuthBusy ? "Подождите…" : emailOTPChallenge ? "Подтвердить" : "Продолжить"}
          onPress={() => { void handleAuthSubmit(); }}
          style={sheetButtonStyle}
        />
        {emailOTPChallenge ? (
          <Button disabled={isAuthBusy} onPress={() => { void handleEmailOTPResend(); }} style={sheetButtonStyle} variant="text">
            <UniversalText textStyle={styles.secondaryButtonText}>Отправить новый код</UniversalText>
          </Button>
        ) : null}
        {canUseBiometricAuth ? (
          <Button disabled={isAuthBusy} onPress={() => { void handleBiometricAuth(); }} style={sheetButtonStyle} variant="outlined">
            <UniversalText textStyle={styles.secondaryButtonText}>{`Войти по ${biometricAuthLabel}`}</UniversalText>
          </Button>
        ) : null}
        {!emailOTPChallenge && supportsWebsiteAuth() ? (
          <Button disabled={isAuthBusy} onPress={handleGoogleSignIn} style={sheetButtonStyle} variant="outlined">
            <UniversalText textStyle={styles.secondaryButtonText}>Войти через Google</UniversalText>
          </Button>
        ) : null}
        {!emailOTPChallenge && supportsWebsiteAuth() ? (
          <Button disabled={isAuthBusy} onPress={() => { void handleWebAuthStart(); }} style={sheetButtonStyle} variant="outlined">
            <UniversalText textStyle={styles.secondaryButtonText}>Войти через сайт</UniversalText>
          </Button>
        ) : null}
      </Column>
    </Column>
  );

  return (
    <Host
      colorScheme="dark"
      seedColor="#22D3EE"
      style={styles.fullScreenHost}
      useViewportSizeMeasurement
    >
      <UniversalSignInWelcome
        onContinue={() => {
          playLightImpactHaptic();
          setAuthError(null);
          setAuthNotice(null);
          requestAnimationFrame(() => setEntryStep("email"));
        }}
      />
      <SignInBottomSheet
        isPresented={entryStep === "email"}
        onDismiss={() => setEntryStep("welcome")}
      >
        {emailContent}
      </SignInBottomSheet>
    </Host>
  );
}

const styles = {
  error: {
    color: "#FFB4A8",
    fontSize: 14,
    lineHeight: 20,
  },
  emailInput: {
    backgroundColor: "#0C2023",
    borderColor: "#42666D",
    borderRadius: 14,
    borderWidth: 1,
    minHeight: 56,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  emailInputText: {
    color: "#E9F7F8",
    fontSize: 17,
  },
  emailRecipient: {
    color: "#A7B9BD",
    fontSize: 16,
    lineHeight: 22,
  },
  fullScreenHost: {
    flex: 1,
  },
  notice: {
    color: "#67E8F9",
    fontSize: 14,
    lineHeight: 20,
  },
  sheetContent: {
    backgroundColor: "#041315",
    paddingBottom: 20,
    paddingHorizontal: 20,
  },
  sheetIntro: {
    color: "#A7B9BD",
    fontSize: 16,
    lineHeight: 22,
  },
  secondaryButtonText: {
    color: "#E9F7F8",
    fontSize: 16,
    fontWeight: "600" as const,
  },
  sheetTitle: {
    color: "#F1FBFC",
    fontSize: 30,
    fontWeight: "800" as const,
  },
};
