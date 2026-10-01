# macOS release readiness — 2026-10-01

## Контекст и границы

- База: `origin/main` `4df3066`; native-consolidation кандидат `d02e8ea` принят поверх неё в изолированном release workspace.
- Универсальная `.app` **0.1.88 (118)** собрана и прошла signature/resource проверки. Это неопубликованный ad-hoc кандидат. Публичное read-only зеркало остаётся **0.1.87+117**, `gatekeeperReady=false`.
- Пользователь потребовал не выключать уже подключённый VPN. В этой проверке не выполнялись live helper/GUI/network операции, установка helper, PF/DNS/route изменения, вход в аккаунт или доступ к credentials.

## Что уже было и что исправлено сейчас

| Область | Уже было | В этом кандидате |
| --- | --- | --- |
| Auth, billing, devices | PKCE/OTP/Google web auth, billing и web fallback | Сохранены; удаление устройства теперь требует свежего подтверждённого idle состояния helper. |
| Каталог/маршруты | AWG3 profiles, smart/full tunnel, recovery | Единый `VpnLocation.isSelectable`, fail-closed manual/auto/fallback выбор; скрытые, maintenance, unhealthy и AWG3=0 узлы не выбираются. |
| Autoheal/DNS/kill switch | Helper watchdog, anti-leak, diagnostics | Сохранены без live-проверки. |
| Updates | Sparkle и отложенная launch-safe проверка | Updater откладывает relaunch при unknown/active/transition/busy/managed route; automatic install по умолчанию выключен. |
| Signing | Локальная сборка | Добавлен explicit inside-out signer; первая проверка ошибочно ожидала XPC, затем исправлена под фактическую схему Downloader+Installer. |

## Проверенная безопасность

- `VpnLocationSelection` возвращает `nil` для пустого/stale manual выбора и сортирует корректные узлы, отправляя NaN/negative latency в конец.
- `DeviceRemovalSafety` запрещает удаление при unknown/active/busy VPN, включая случай `activeTunnel == nil`; перед DELETE AppState обновляет helper status.
- `NativeVPNUpdateSafetyPolicy` считает неизвестное состояние unsafe. Sparkle postpones updater-driven relaunch до подтверждённого idle; обычный пользовательский quit не переопределяется этим guard.
- Подготовленные офлайн unit/isolation suites прошли. Полный XCTest **не пройден**: Command Line Tools возвращают `no such module 'XCTest'`.
- Universal app/helper builder собрал обе архитектуры. Первый signing check упал из-за неверного XPC expectation; после корректировки Downloader+Installer check прошёл во втором запуске.
- Финальная сборка 0.1.88+118 выполнена после фиксации SHA-256 всех native Swift sources; после сборки эти хеши совпали. App/helper: `x86_64 arm64`; `SUAutomaticallyUpdate=false`; relocatable/missing-resource и update-response probes прошли.
- Публичный release gate выполнен без installed-runtime проверки: exit 1, `app is ad-hoc signed; Developer ID signature required`. Developer ID Application/Installer identities на этом хосте: 0/0. Не обходить этот gate.

## Артефакты транзакции

Четыре роли; буквальные команды, stdout/stderr, статусы и хеши находятся в `VERIFICATION.txt`:

- `/Volumes/D/Projects/mobile/macos-release-transaction-20261001/MODIFIED_FILE.tar.gz`
- `/Volumes/D/Projects/mobile/macos-release-transaction-20261001/DIFF_FILE.patch`
- `/Volumes/D/Projects/mobile/macos-release-transaction-20261001/VERIFICATION.txt`
- `/Volumes/D/Projects/mobile/macos-release-transaction-20261001/ROLLBACK.sh`

## Parity limits

Полного parity с Android пока нет: macOS не реализует Android per-app routing. Текущий root helper маршрутизирует IP-направления, а не процессы; нельзя имитировать защиту фиктивным app picker. Поддерживаемый Apple app-proxy путь требует NetworkExtension entitlement и управляемой конфигурации. APNs/background push также нет; текущий foreground SSE/realtime не является заменой background push.

## Незавершённые TODO

- `macos-native/Sources/VEXNativeMac/Services/SparkleUpdaterService.swift`: `TODO(vpn-update-safety)` — VM qualification deferred Sparkle handoff до включения production automatic install.
- `macos-native/Sources/VEXNativeMac/Models/VEXModels.swift`, `VpnRoutingMode`: per-app provider и isolated routing/leak acceptance отсутствуют. Возврат `nil` при пустом каталоге уже реализован и не является незавершённым TODO.
- `macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift`, `startCustomerRealtime`: metadata пока используется только для refresh; следующий офлайн-шаг — дедупликация foreground-уведомлений. Это не background push и не доказанное число непрочитанных сообщений.

## Следующие действия (не более пяти)

1. Добавить чистую foreground notification policy поверх SSE metadata с дедупликацией; затем opt-in desktop delivery. Не выдавать её за APNs или счётчик непрочитанных сообщений.
2. Запустить полный XCTest с Xcode; реализовать process-scoped provider и APNs с необходимыми signing/entitlement gates.
3. На отдельном Mac/VM проверить signed helper install/rollback, handshake, IPv4/IPv6/DNS/HTTPS, failover и deferred Sparkle update. Пользователь подтвердил, что стенда пока нет.
4. Подготовить подписанный/notarized release, обновить согласованную native version metadata; ad-hoc кандидат не устанавливать поверх активного VPN.
5. Публиковать 0.1.88+118 только после всех acceptance gates и отдельного явного разрешения владельца.

## Первичные справки

- [Apple: NEAppProxyProviderManager / managed Per-App VPN](https://developer.apple.com/documentation/networkextension/neappproxyprovidermanager)
- [Apple: Creating distribution-signed code for macOS / inside-out signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Sparkle: automatic checks versus installation](https://sparkle-project.org/documentation/customization/)
- [Sparkle: shouldPostponeRelaunchForUpdate delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
