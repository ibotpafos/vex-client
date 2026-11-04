# Android connection cancellation acceptance

The signed candidate from source `706bfd57972a4b2bbb5f76bc5573c250e88444c3`
was exercised on a physical Mi A1 running Android 9. Its installed APK SHA256
matched `6ee1f0b7aadfdf310e09fc3a602f20152cfbb183fbb307b40858ffe102cef592`.
Installation preserved the existing login and settings, and the previous
installed APK was retained with its matching release certificate.

The first measured connection verified in 2,172 ms. The pending green
presentation, native tunnel, DNS and browser HTTPS were observed. A canceled
operation also completed 5,347 ms of handshake verification and incorrectly
emitted success before teardown; it must not count as a successful user
connection. This is operator evidence, not a fleet success rate.

## Reproduced cancellation failure

Start a connection and cancel while profile or native preparation is pending.
The canceled operation previously continued through native startup and
verification before checking its generation. It could briefly restore the
pending display, emit a success event, and tear down a newer operation in the
same login. Physical recording and native start/stop events reproduced this;
15 initial regression cases failed against the candidate source.

The connection flow now checks both the login and connection generation at
asynchronous boundaries and during handshake verification. Canceled completions
cannot publish success, start a fallback, or release another operation's busy
state. Automatic startup uses the same generation fence. Verification remains
cancellable, and native stop failures are surfaced.

## Validation and release gate

`npm run check` and `npm run contract:check` pass. The tests exercise cancellation
during profile resolution, diagnostics, application selection, route preparation,
status reads, native startup, verification, fresh-profile fallback and location
persistence, plus replacement connections and automatic startup completion.
Existing cross-account/session and handshake-deadline cases remain covered.

This follow-up still requires a new signed candidate and physical reacceptance
before publication. Repeat rapid cancel, cancel followed by a new connection,
normal connection, background/foreground, DNS/HTTPS and loss/recovery of Wi-Fi.
The owner confirmed that the available phone has Wi-Fi only. Wi-Fi was
restored after the handover attempt; Wi-Fi/cellular acceptance requires a
different device with mobile connectivity. No production promotion follows from these local
checks alone.

## Подготовка до нажатия Connect

Профиль выбранной локации уже загружается заранее через `useVpnProfileState`,
сохраняется в памяти и защищённом hot cache; подходящий профиль используется
до online fallback. Однако перед native start отдельно ожидалась необязательная
сетевая диагностика, до 1500 мс. Поэтому `profile_resolve_ms` включает больше,
чем время получения профиля с API.

На Android подготовка этой диагностики теперь начинается при готовом профиле,
пока приложение активно и VPN отключён, а также при возврате приложения.
Connect переиспользует действующий receipt той же сети, аккаунта и устройства
или присоединяется к уже начатой подготовке. Холодная подготовка остаётся
ограничена 1500 мс; таймаут освобождает следующий запрос, поздний ответ не
может заменить новый результат. При смене login или запуске VPN в процессе
подготовки attribution не принимается. Сетевые настройки и проверка handshake
сохраняются; наблюдение через VPN не объявляется underlay proof.

Пять регрессий падали до исправления. Проверены повторное использование,
совместный запрос, смена сети/аккаунта/устройства, устаревшая сессия, таймаут,
поздний ответ и начало VPN во время capture. Полный `npm run check` прошёл.
Физическое ускорение и приёмка этого source требуют нового подписанного APK;
цифры старых кандидатов не доказывают результат новой оптимизации.
