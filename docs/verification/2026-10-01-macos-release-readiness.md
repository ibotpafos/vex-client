# macOS release readiness — 2026-10-01

## Контекст и границы

- База: `origin/main` `4df3066`; native-consolidation кандидат `d02e8ea` принят поверх неё в изолированном release workspace.
- Универсальная `.app` **0.1.88 (118)** собрана и прошла signature/resource проверки. Это неопубликованный ad-hoc кандидат. Первый сохранённый снимок публичного read-only зеркала: **0.1.87+117**, `gatekeeperReady=false`; это историческое наблюдение, не утверждение о новом опубликованном релизе.
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

## Продолжение: исполнимые lifecycle-регрессии

- Фактические тела SSE callbacks скомпилированы и исполнены с in-memory transport/backend: same-account dedupe, stale callbacks, resync без баннера, support/releases, смена аккаунта и revocation. Первый запуск упал из-за fixture `waitForAdd`, который ожидал любой старый add вместо нужного количества; исправленный count-latch прошёл. Исходная ошибка сохранена отдельно.
- Отклонение сессии теперь увеличивает `customerRealtimeGeneration` **до** reset/retry; ранее поставленная в очередь доставка больше не проходит guard. Revocation также отменяет старый SSE transport. Это не команда отключения VPN.
- `deliver` согласует уже полученный snapshot системного разрешения: внешний deny отключает opt-in и удаляет только service-owned notices. Payload содержит только generic title/body; SSE ID остаётся в bounded dedupe, а не в очереди доставки.
- `withSessionRetry` и `resolveProfileForAuthenticatedSession` связывают ошибки/ответы с токеном и `authenticatedSessionGeneration`: старый 401 не refresh/retry/expire новую сессию. Generation меняется при login/unlock/reset/termination, но не при обычном token refresh. `sessionChanged` из подготовки профиля не вызывает helper disconnect cleanup.
- Исполнимый fake harness реальных retry/entitlement/profile bodies воспроизвёл ошибки до исправления (exit 1), после исправления все stale-path assertions прошли (exit 0). Рабочие current-session retry/expiry принимаются и до, и после изменений.
- Реальные `loadUser`/`refreshLocations` прошли same-token re-login fixtures: поздние success/error не меняют пользовательские данные. `loadBilling` получил такие же generation/token/owner guards; его отдельная исполнимая regression входит в текущий offline gate.
- Эти результаты не доказывают весь `connectWithAutopilot` или реальный tunnel/update/permission UX. Последующая проверка `performConnectVPN` описана ниже; полный релиз и parity всё ещё не подтверждены.

## Продолжение 4: границы авторизованного подключения

- Записанный runner действительно был запущен первым. Он выявил продолжение старого connect intent после auth boundary (runtime SIGTRAP, exit 251). Ошибка не была подменена анализом текста; исходные stderr/exit сохранены.
- `ensureAuthenticatedSessionCurrent` проверяет generation, текущий access token и owner; `ensureConnectStillDesired` сначала классифицирует auth invalidation как `sessionChanged`, а не как cancellation с disconnect cleanup. Контекст передаётся через `performConnectVPN`, autopilot, подготовку туннеля, handshake polling и смену локации. Config writing в rotation/fresh/failover откладывается до ближайшей проверенной admission границы; default `writeHelperConfig=true` у service сохранён для совместимости.
- Фактическое тело `performConnectVPN` исполнено с fake auth/entitlement/connector gates. Поздние ответы не меняют replacement UI/tunnel, не начинают следующий connector и не ставят stale report. Нормальный путь, ordinary same-account refreshed profile token, отмена и сообщение ошибки остаются рабочими в fixtures. Это не live helper acceptance.
- Фактическое тело `connectPreparedTunnel` и обе проверки контекста исполнены с fake readiness/config/connect/handshake. BASELINE: все четыре `stopped=false`, exit 1; MODIFIED: все `stopped=true`, exit 0; `valid_current=true` в обоих случаях. Уже отправленные до границы readiness/write/connect допускаются (счётчик 1); последующие действия после наблюдаемой границы запрещены. Handshake в этом тесте — fake downstream, а не runtime проверка тела `verifiedHandshake`.
- Реальное `VpnAdmissionRecovery.retryFreshProfile` сохраняет default retry/failover и config rejection. Новый caller predicate прекращает failover для auth invalidation/cancellation: BASELINE stale/cancel failovers=1/1, MODIFIED=0/0; transient/default=1/1 и normal path=true сохранены. Это только service-level runtime, не вся autopilot orchestration.
- Исправлены именно fixture-ошибки: отсутствующее добавление extracted auth guard в prepared harness, ранняя проверка queued report без count latch и неправомерное ожидание `nil` вместо replacement UI, записанного после suspension. Ошибки компиляции и ранние SIGTRAP сохранены; окончательные negative checks печатают все outcomes и возвращают exit 1 без crash.
- Read-only source review не подтвердил нового stale-command дефекта: helper up/down уже отправлены до response-await; post-await guard не может отменить отправленную команду, но предотвращает дальнейшие действия. Нельзя объявлять это атомарным откатом сети. CGRX risk scan partial: native Swift исключён, Python dynamic dispatch неизвестен; Narsil audit не выполнялся.
- Полная actual-body матрица policy/probe/usage/rotation/fresh/failover остаётся отдельным unfinished gate. `TODO(autopilot-full-runtime)` находится у фактического `connectWithAutopilot`; compile-only подготовка runner не считается исполнением runtime.
- Read-only production deploy/fleet evidence в этом цикле вернули timeout 20s. Это не доказательство ни аварии, ни здорового fleet. Отчёт release truth остаётся watch; production ничего не менялось.

- После этих native изменений повторно выполнены полный offline aggregate (exit 0), universal app/helper build (exit 0), strict signature/resources/metadata проверки (exit 0). Source hashes зафиксированы и повторно сверены. Public gate снова exit 1: только ad-hoc signature; никакой installed-runtime проверки, установки или публикации.

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
- `macos-native/Sources/VEXNativeMac/Stores/VEXAppState.swift`: `TODO(autopilot-full-runtime)` — actual-body policy/probe/rotation/fresh/failover runtime matrix ещё не исполнена; main/prepared boundary fixtures уже пройдены.
- `macos-native/Sources/VEXNativeMac/Services/CustomerRealtimeService.swift`: APNs/background delivery не реализован; credentials/entitlements/device qualification отсутствуют. Foreground policy и opt-in wiring уже реализованы, это не незавершённый TODO.

## Следующие действия (не более пяти)

1. Выполнить next `qualify-autopilot-auth-boundary.py` на фактическом `connectWithAutopilot` с inert downstream continuation gates; завершить policy/probe/rotation/fresh/failover matrix. Main/prepared/auth/recovery fixtures уже исполнены; реальный permission/banner остаётся отдельным acceptance.
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


## Continued offline qualification: cache ownership

The same native candidate now scopes `VPNProfileCache` by hashed account + installation identity and checks the record owner. All eight AppState profile calls pass the immutable operation owner, including warmup and rotation. Unknown ownership skips cache; unowned/legacy records are not assigned a guessed owner. Logout cancels queued warmup; an already dispatched late A result can finish only in its captured A namespace. This does not revoke an already-dispatched server request or promise atomic cancellation.

Actual Swift cache/record runtime (disposable injected filesystem, actual routing enum) reproduces cross-account reuse/late overwrite on pristine source, rejects it on modified source, and reproduces it after source-copy rollback. Same-owner hits and routing separation are retained. The earlier Python cache reimplementation is rejected as runtime evidence. Actual autopilot orchestration/guard/recovery matrix and actual handshake polling with inert downstream fixtures are now in the aggregate offline suite; no real tunnel/peer acceptance is implied. Throwing rotation/profile/failover variants still need extension.

APNs sender dependency exists only as an unintegrated isolated backend candidate with fake-transport tests. Configuration/provider composition, registration compatibility, client opt-in registration and background/unread lifecycle are unfinished. No production APNs delivery is claimed. Per-app routing, isolated installation/network/update acceptance, Xcode XCTest and Developer ID/notarization remain outside verified release readiness.
