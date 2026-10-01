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
| Уведомления | Foreground SSE только обновлял данные | Явный opt-in, дедупликация support/releases, нативный permission-gated UserNotifications backend и foreground delegate; никакого APNs или выдуманного счётчика сообщений. |

## Проверенная безопасность

- `VpnLocationSelection` возвращает `nil` для пустого/stale manual выбора и сортирует корректные узлы, отправляя NaN/negative latency в конец.
- `DeviceRemovalSafety` запрещает удаление при unknown/active/busy VPN, включая случай `activeTunnel == nil`; перед DELETE AppState обновляет helper status.
- `NativeVPNUpdateSafetyPolicy` считает неизвестное состояние unsafe. Sparkle postpones updater-driven relaunch до подтверждённого idle; обычный пользовательский quit не переопределяется этим guard.
- Подготовленные офлайн unit/isolation suites прошли. Полный XCTest **не пройден**: Command Line Tools возвращают `no such module 'XCTest'`.
- Universal app/helper builder собрал обе архитектуры. Первый signing check упал из-за неверного XPC expectation; после корректировки Downloader+Installer check прошёл во втором запуске.
- Финальная сборка 0.1.88+118 выполнена после фиксации SHA-256 всех native Swift sources; после сборки эти хеши совпали. App/helper: `x86_64 arm64`; `SUAutomaticallyUpdate=false`; relocatable/missing-resource и update-response probes прошли.
- Публичный release gate выполнен без installed-runtime проверки: exit 1, `app is ad-hoc signed; Developer ID signature required`. Developer ID Application/Installer identities на этом хосте: 0/0. Не обходить этот gate.
- Продолжение цели добавило SSE → pure policy → локальные уведомления с явным opt-in (default false). Fake backend исполнил denied/error/preview, disable-during-authorization, поздний add после logout и повторный ID в новом epoch. Метаданные события не попадают в баннер: только общие русские сообщения, backend IDs — transient epoch/sequence.
- Клиент изолирует старые callbacks поколением потока и token guard; logout, смена аккаунта, явная revocation и завершение сбрасывают уведомления. Same-account refresh сохраняет dedupe. Permission IPC не задерживает обновление entitlement/account.
- Фактические тела `applySessionRefreshResult`, `loadUser`, `refreshLocations` скомпилированы в fake-transport harness: late logout/account-switch результаты не восстанавливают и не перезаписывают сессию/данные, текущие результаты принимаются. Это не полный XCTest и не GUI acceptance.

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
- `macos-native/Sources/VEXNativeMac/Services/CustomerNotificationService.swift`: `TODO(notification-acceptance)` — реальный opt-in/permission sheet/banner на изолированном профиле не проверен; fake backend этого не доказывает.
- `macos-native/Sources/VEXNativeMac/Services/CustomerRealtimeService.swift`: APNs/background delivery не реализован; credentials/entitlements/device qualification отсутствуют. Foreground policy и opt-in wiring уже реализованы, это не незавершённый TODO.

## Следующие действия (не более пяти)

1. Дополнить runtime wiring coverage исполнимым SSE callback/in-memory transport integration; на изолированном профиле отдельно проверить permission/banner. Pure policy, fake delivery и late-session guards уже пройдены.
2. Запустить полный XCTest с Xcode; реализовать process-scoped provider и APNs с необходимыми signing/entitlement gates.
3. На отдельном Mac/VM проверить signed helper install/rollback, handshake, IPv4/IPv6/DNS/HTTPS, failover и deferred Sparkle update. Пользователь подтвердил, что стенда пока нет.
4. Подготовить подписанный/notarized release, обновить согласованную native version metadata; ad-hoc кандидат не устанавливать поверх активного VPN.
5. Публиковать 0.1.88+118 только после всех acceptance gates и отдельного явного разрешения владельца.

## Первичные справки

- [Apple: NEAppProxyProviderManager / managed Per-App VPN](https://developer.apple.com/documentation/networkextension/neappproxyprovidermanager)
- [Apple: Creating distribution-signed code for macOS / inside-out signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Sparkle: automatic checks versus installation](https://sparkle-project.org/documentation/customization/)
- [Sparkle: shouldPostponeRelaunchForUpdate delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Apple: явное разрешение на уведомления](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
