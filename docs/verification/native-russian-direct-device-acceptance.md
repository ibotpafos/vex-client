# Проверка российского DIRECT перед выпуском

14 октября 2026 владелец разрешил завершить сборки и доставку после проверок.
Проверку iOS на устройстве владелец выполняет сам. macOS исключён из текущего
выпуска и дальнейших проверок по его последней инструкции. Выпуск остаётся
кандидатом до физической проверки конкретных подписанных артефактов.

## iPhone / iPad

Нужна новая сборка из `codex/ru-direct-native-20261013`, с новой серверной
signed routing policy v2. Проверка старого приложения из публичного канала
не подтверждает этот код. Для сборки/установки нужны полный Xcode, iOS SDK,
Apple Development identity и provisioning с Network Extension / App Groups.
На текущем Mac этих средств подписи и полного Xcode нет. Ветки исходников
не являются подписанным IPA или доставкой в TestFlight/App Store.

В готовой среде с существующей подписью установить зависимости через `npm ci`
и `pod install --deployment` в `ios/`. Из корня вызвать
`GOTOOLCHAIN=go1.26.9 IOS_DEVELOPMENT_TEAM=<TeamID> IOS_CONFIGURATION=Release npm run ios:device-build`.
Device builder проверит компилятор перед sync/build; нужно сохранить именно
commit этой сборки и её подпись. Этот шаг требует готового Apple Developer
окружения и не создаёт подтверждение проверки на устройстве.

1. Записать commit сборки, её версию, номер, SHA-256 и версию iOS.
2. Включить Smart routing и защиту от утечек. На Wi-Fi проверить российские
   домены `.ru`, `.su`, `.рф` и российский сервис вне этих зон. Они должны
   получать прямой выход; иностранный контрольный адрес — VPN-выход.
   Само открытие страницы не доказывает выбранный маршрут: подтвердить путь
   сетевым наблюдением или контролируемым endpoint.
3. Повторить на мобильной сети, dual-stack и доступной IPv6-only/NAT64 сети.
   Проверить DNS и IPv6: иностранный трафик не выходит через физическую сеть.
4. При активной защите прервать VPN-транспорт, оставив сеть доступной.
   Проверить, что иностранный трафик блокируется, российский DIRECT соответствует
   действующей политике, а возврат сети/on-demand не возобновляет прежние ключи
   после защищённой остановки. Затем восстановить соединение.
5. Сменить Wi-Fi/мобильную сеть, свернуть/вернуть приложение и перезапустить
   устройство. Подтвердить сохранение защиты и успешное восстановление.
6. На изолированном стенде проверить истечение/ошибочную подпись политики:
   отсутствует широкий DIRECT или DNS fallback. Выполнить обновление и откат;
   активная защита не снимается незаметно. Отключение защиты проверить отдельно
   явным действием пользователя.

Сохранить короткий результат каждого пункта без логинов, IP клиента, ключей
и raw packet captures. Ошибку или непроверенный сценарий отметить явно.
Контролируемый обрыв/expiry относятся к тестовому профилю, а не к рабочим peers.

## Android

ADB-доступ и тестовая установка разрешены владельцем. Debug APK имеет отдельный
package `.debug`, внешний Metro bundle и тестовый signer; он подтверждает сборку
и загрузку JNI, но не является обновлением production package. Для окончательной
проверки использовать standalone подписанный candidate с embedded bundle,
совпадающим production signer и обеими поддерживаемыми ARM ABI. Пройти сценарии
iOS выше, дополнительно проверить always-on/блокировку без VPN, Doze, смерть
процесса и загрузку на поддерживаемых API. Не объявлять APK установленным или
проверенным только по успеху Gradle.

## Android — текущий кандидат17октября

На USB Mi A1/API28 штатное signed обновление1.0.69 →1.0.70/code1007078
сохранило вход, first-install timestamp и настройки. Проверены actual APK SHA,
production signer, R8 mapping/source receipt, обе ABI, embedded bundle и JNI;
это не подтверждение пакетной маршрутизации. APK SHA-256:
`45bec1b486a7f41167758ec994729b644437568828f88331045c6e353c204e29`.
Обычный UID-наблюдатель подтвердил базовые RU/foreign HTTPS и foreign UDP DNS
на IPv4. На Wi-Fi отсутствует IPv6 uplink; IPv6 защита ещё не квалифицирована.

Реальное подключение1.0.70 выявило отсутствие подписи прежней регистрации до
старта VPN. Source `705378724c0efc49f6ac7bd87dcc713e2559f52d` исправляет Android/iOS
native P256 через Expo CSPRNG/hash и pinned MIT noble2.4.0, сохраняя JWK/P1363.
31 identity/account/legacy transport проверка и полный client check прошли.
Нативный транспорт для старого API запрашивает full tunnel без stale split cache.

Замена1.0.71/build79/code1007179 успешно собрана в manual no-publication
[39056433324](https://github.com/ibotpafos/vex-client/actions/runs/39056433324),
source7053787/tree d07ca378, orchestration227efab. Actual APK SHA-256:
`50cbda9f975a5ed6edac34e24b9c1e64cd73704ba80ed1228c7327e1605c2360`.
Независимые signer/aapt/байты/sidecar/R8/source/both-ABI/Go/embedded-bundle и
MIT notice проверки прошли, как и JNI load/protector/invalid-admission на телефоне.
JNI probe явно оставляет packet acceptance NOT_RUN. Raw ZIP digest независимо
не пересчитывался. Штатное обновление1.0.70 →1.0.71 сохранило first-install
и вход; ошибка прежней регистрации не повторилась, реальный VPN подключился.

Обычный application UID подтвердил смену зарубежного IPv4 HTTPS egress с ISP
на VPN, RU/foreign HTTPS и foreign UDP DNS на стабильном Wi-Fi. RU пока имеет
тот же VPN egress: новая signed-v2 policy/backend ещё не развёрнута. Прямой RU
маршрут не принят. При возврате Wi-Fi трафик восстановился, в фоне проверки
проходили; UI позднее сохранял DNS-предупреждение, несмотря на успешные пробы.
Эта неоднозначность требует продолжения device QA и не закрывает recovery gate.

Мобильная передача данных фактически не установилась: оба modem data state0,
физического default route нет. IPv6 uplink также отсутствует. В Android Settings
always-on явно не поддержан, как и в двух текущих manifest VpnService declarations;
OS флаги не менялись. Controlled native protected-stop, force-stop/reboot,
независимый DNS egress и IPv6 leakage не подтверждены. Не заменять эти результаты
полным native acceptance receipt. После явного Disconnect исходный ISP egress
вернулся; Wi-Fi восстановлен, Smart/AntiDetect true, autoconnect/auto-selection
false, VPN остановлен, как до QA. Вход, данные и ключи не сбрасывались.

Проверенный APK/partial evidence сохранены в
`/Volumes/D/VEX-Releases/ru-direct-20261017`. Серверная сборка API/scheduler через
MCP остановилась до build/push на существующем disk guard:9,8ГБ свободно на D
при минимуме40ГБ. Нужны минимум31ГБ и затем signed-v2 backend/device QA.
macOS исключён; его VPN/сеть/trust не изменялись.

## Windows и Linux

Windows: реальные Wintun/firewall/service и signed install/upgrade/rollback/
uninstall проверки обязательны. Старый fixture официального AWG runtime
не подтверждает новый routed child. Portable PowerShell fixtures и cross-build
x64/ARM64 — подготовка к этой проверке. Новый router собирается из reviewed
source в существующем manual packaging job; packager подписывает и фиксирует SHA.

Linux: проверить CLI в изолированном namespace с nftables/resolved, защищённую
остановку/restart, смену uplink, обе IP семьи и откат. Нативного опубликованного
GUI Linux в проекте пока нет; общий AWG config не заменяет этот routed CLI.

## Выпуск

Проверенные receipt должны связывать точные server/client commits и SHA-256
подписанного артефакта. VEX MCP `vpn_release_truth` с `includeNativeAcceptance`
проверяет наличие и целостность записей, но не выполняет испытание или выпуск.
Для текущего scope указать `nativePlatforms: [ios, android, windows, linux]`.
После source CI/review выполнить MCP deploy plan, scoped backend acceptance,
проверку signed policy и только затем доставку прошедших проверку клиентов.
Подтвердить update metadata, фактический download и принятие обновления на
устройстве. Новость о выпуске публиковать после production acceptance.
