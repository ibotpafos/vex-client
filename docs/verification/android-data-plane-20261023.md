# Android1.0.79: DNS и HTTPS перед подтверждением VPN

23–24 октября 2026. Выделенный Mi A1, Android9/API28/arm64/user0.
Приватный кандидат, без публикации и OTA. Активный VPN Mac не настраивается;
серверные сетевые правила, службы и peers других устройств не меняются.

## Условие подключения

Android требует одновременно handshake, допущенный native peer и успешный
обмен DNS→TLS→HTTP через AWG NetTUN. Без подтверждения интерфейс остаётся в состоянии подключения/проверки,
без зелёного успешного состояния. Только после
приёмки появляются «Подключено» и «Соединение защищено». Heartbeat успешного
подключения не отправляется, пока native proof отозван.

DNS использует резолверы из профиля через `Router.net.LookupContextHost`.
Затем HTTPS обращается к разрешённому адресу через тот же `Router.net`,
не через классификатор DIRECT и не через сокеты UID приложения. Поэтому
исключение самого VEX из выбранных приложений не превращает обычный JS fetch
в ложное доказательство. Системный resolver, HTTP proxy, redirects, cookies,
авторизация и физический запасной dialer в этой проверке не используются.

TLS проверяет hostname и системную цепочку доверия. Нужны HTTP200 и корректный
публичный IP echo в ограниченном ответе. Сам IP не возвращается в приложение,
не сохраняется и не логируется. Основная цель — `one.one.one.one/cdn-cgi/trace`,
резервная — `api.ipify.org/?format=json`; у каждой свой DNS и HTTPS. Успешный
TCP SYN, счётчики или handshake не заменяют ни DNS, ни HTTP-ответ.

Выбор управляемого сервера связан с профилем и реальными UAPI public keys.
Canary идёт через тот же AWG peer; геолокация IP не является security gate.
Географическое соответствие дополнительно проверяется на стенде отдельным UID.

## Владение и сроки

Подтверждение находится только в памяти и принадлежит peer generation,
поколению физической сети и конкретной попытке. Перед приёмкой повторно
проверяются владельцы и UAPI keys. Смена узла/сети, disconnect и поздний ответ
не могут подтвердить другое соединение. Проверка выполняется вне tunnel mutex,
поэтому управление соединением остаётся доступно.

- Общий бюджет12с: до6с на сервис, до3с на DNS.
- Повтор после ошибки — не чаще3с.
- Обновление успешного proof начинается через45с; срок действия60с.
- Ошибка обновления немедленно отзывает успешный proof; время монотонное.
- Connect, switch и watchdog recovery ожидают native proof до25с.

JS также требует совпадения `expectedDataPlaneGeneration` с новым native
подключением. Новая операция управления очищает status cache и увеличивает
его epoch: позднее чтение или завершение старой операции не переписывает
актуальный cache и не отсоединяет новое in-flight чтение. Повторное
использование уже подтверждённого туннеля не требует ожидания следующего rekey.
Три отдельные регрессии воспроизведены на source860d4b6, затем исправлены.
Всего добавлено12 JS проверок; полный `npm run check` прошёл на итоговом source.

Отдельно устранено прежнее подавление событий watchdog: он учитывал локальный
сбой, но мог удержать предыдущий зелёный UI на время восстановления. Отозванный
`dataPlaneVerified=false` теперь сразу попадает в интерфейс, включая DOWN и
blocking. Pending не вызывает цикл reconnect; подтверждённая ошибка остаётся
в учёте восстановления. Ошибка HTTPS и общий timeout не выдаются за DNS-сбой.

Новые JNI entry point и status field добавлены без изменения существующих
методов, API-схем, ключей или настроек. Старый native binary без proof не
принимается как подтверждённый. Runtime1.0.79 требует подписанное обновление
APK; OTA поверх старого native runtime не выполнялась.

## Проверки исходника и Android runtime

| Среда | Проверка | Результат |
| --- | --- | --- |
| JS | Handshake/counters/legacy flag без proof; ожидание DNS/HTTPS; отмена; восстановление; отзыв зелёного UI | RED на прежнем поведении, GREEN после исправления |
| Host | Полный `npm run check` | PASS |
| Go | Полный `go test -race ./...` | PASS |
| Mi A1 ARM64 | Реальные NetTUN packets, DNS/TCP/TLS/HTTP с синтетическим peer | PASS |
| Mi A1 ARM64 | Отказ DNS, пустой HTTP, redirect,503, неверный сертификат/echo, смена сети/закрытый transport, резервный сервис | PASS, физические callbacks не использованы |
| JVM и Mi A1 ART | Четыре теста владения, ошибок, expiry и позднего завершения | PASS |
| Java bridge | Apply/reverse/reapply дополнительного patch на отдельной копии | PASS |

Packet fixtures не создают host listeners, OS TUN, routes или DNS settings.
Android ART запускает тот же Kotlin source класса proof. Первая race-оснастка
имела слишком короткие тестовые deadlines; HTTP fault теперь вводится после
наблюдаемого достижения peer, дедлайны подготовки увеличены. Это изменение
тестового контроля, production budgets не расширялись.

## Источник кандидата

- Android1.0.79/build87/code1007987/runtime1.0.79.
- Source `509f608ff94ff7d2e0fd498f1727f7f36cb9468a`, tree `a9d0a6eed707bad57c8b0a8ae11591d2283db48c`.
- Оркестрация `adeac105dbc01e634d47248d375b60dc7beac0f3`.
- [CI39990338878](https://github.com/ibotpafos/vex-client/actions/runs/39990338878).
- Прежний CI39984420243 отменён при аудите обработки отзыва proof;
  signing cleanup PASS, артефакт на телефон не устанавливался.

CI успешно завершил quality, Go race, native JVM, release build, загрузку
обоих артефактов и удаление signing material. Артефакты сверены по GitHub ZIP
digests, CRC, source/tree/workflow/run, подписи, обеим ARM ABI, runtime, bundle,
R8 и новому JNI export. Совместимость обновления проверена с фактически
установленным APK1.0.78. Итоговый APK установлен поверх него на Mi A1;
первое время установки и системные предпочтения сохранены, данные не очищались.

- APK: 44 010 900 bytes, SHA256 `96134be9e00b21447de29249facd3966a8e095db32857477f8a15787ec0460f6`.
- R8: SHA256 `3f6349de713faf9e28c87e9edf40a70c6b47d97f4d494c3bbfb2dbf14b7d8a77`.

## Физическая приёмка APK

| Сценарий | Проверенный результат |
| --- | --- |
| NL/Noord после установки | Новый peer/endpoint NL, proof487мс, обычный UID: DNS, HTTPS200 по имени и числовому адресу, STUN с NL egress |
| Повтор proof без нового handshake | PASS, тот же peer/network/handshake, интервал46.18с |
| NL→DE/Kern | Новый допущенный peer/endpoint DE, proof514мс, DNS/HTTPS/STUN с DE egress |
| Потеря Wi-Fi на DE | «Подключено» отозвано, показана проверка; после возврата network generation4, новый proof361мс, обычный трафик DE прошёл |
| DE→NL после rebind | Новый peer/endpoint NL, proof408мс, обычный трафик с NL egress |
| Только выбранное тестовое приложение | Android VPN UID range ровно10167, VEX UID10116 исключён; proof379мс и обычный трафик прошли через NL |

Native proof log и admission связаны одним UUID и UAPI fingerprints; отдельный
UID проверяет реальный выход по инвентарю. Порядок сопоставлен с Android clock;
это выборочные кадры, не запись каждого frame/packet. После проверки
восстановлены все приложения/selected0, auto-connectOFF, auto-serverOFF, Noord
и VPNoff. Helper, его JAR/XML, пустые owned dirs и тестовый ключ удалены.
Исходные null Always-on/lockdown, Wi-Fi/data/airplane/timeout и Awake сохранены;
login/first-install сохранены. Read-only Mac DNS/NC hashes совпали до/после.

### Открытый сбой API при переключении

До Wi-Fi rebind переход DE→NL дважды закончился
`SSLHandshakeException: Connection closed by peer` при обращении к API.
Клиент вернул проверенный DE и показал Kern, вместо ложной выбранной NL.
В тот же период отдельный UID через DE получил VEX origin HTTPS200 с
корректным TLS; host egress DE также дал200. После rebind переключение прошло.
Причина не установлена: stale DNS/connection state — только гипотезы.
TODO в `src/vpn/useVpnConnection.ts` сохраняет этот integration gap до
контролируемого воспроизведения и исправления. Полная беспроблемная приёмка
переключения и готовность общего выпуска не заявляются.

## Отдельная проверка INCY

На Mi A1 установлено официальное INCY3.8.1 поверх3.7.9, с тем же APK signer,
сохранением данных и6 профилей. Владелец подтвердил отдельную подписку стенда.
Начальный NL на3.7.9 не пропускал DNS/HTTPS при работающем таймере, прямой
контроль прошёл; FI и DE прошли с правильным egress. После обновления повтор
NL прошёл; причинная связь с версией не доказана при изменявшейся инфраструктуре.
На3.8.1/NL Wi-FiOFF10.13с оставил только VPN и таймер INCY, все четыре пробы
при этом не проходили. Возврат сети и screen-off12с/Dozing/wake восстановили
трафик без ручного reconnect; deviceidle былACTIVE, глубокий Doze не доказан.
Девять последующих пакетов за160.084с дали36/36 сетевых успехов и9/9
Instagram Web200. Публичные API/CDN root404 доказывают лишь DNS/TLS/HTTP
доступность. Instagram app, login, Reels/video и iPhone не приняты.

Эта VEX-сборка и её `dataPlaneVerified` не изменяют INCY. По завершении обе
версии остались установленными на стенде, оба VPN выключены.



## Границы и источники

Canary подтверждает доступность DNS и HTTPS через допущенный VPN peer в момент
проверки; он не обещает доступность каждого сайта и не отменяет выбранный
пользователем split tunneling. Mi A1 не имеет квалифицированного LTE/IPv6
uplink и использует FDE; FBE до unlock и kernel suspend не принимаются этим
проходом. Ранее принятая защита загрузки описана в
[проверке1.0.78](android-recovery-boot-20261023.md).

Использованы существующий MIT AWG netstack и стандартные Go HTTP/TLS, без новой
production зависимости: [AWG Netstack](https://pkg.go.dev/github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack),
[Go HTTP Transport](https://pkg.go.dev/net/http#Transport),
[Cloudflare trace](https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/).

Private receipts, исходники оснастки и исключённые попытки:
`/Volumes/D/Codex Storage/evidence/vpn-data-plane-20261023/`.
Локальные artifacts/caches находятся наD; временные Android-файлы — в
платформенном хранилище выделенного телефона.
