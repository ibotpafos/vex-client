# Android 1.0.80: сохранение DNS при смене peer

24 октября 2026. Выделенный Mi A1/API28/arm64/user0. Приватный кандидат,
без публикации/OTA и серверных сетевых изменений. Проверка продолжает
[приёмку1.0.79](android-data-plane-20261023.md).

## Ошибка и исправление

При сохранённом Android VPN Network новый Router создавал пустую таблицу
виртуальных DNS-адресов. Приложение могло продолжить использовать адрес API
из своего DNS cache: прежняя идентичность терялась либо совпадала с первой
новой записью другого origin. TCP принимался, но TLS получал EOF. Отдельный UID
с новым DNS lookup мог при этом успешно получать HTTPS200.

Регрессия с реальными gVisor TCP packets, проверяемым сертификатом и HTTP200
воспроизводит EOF на прежних production-файлах через Go overlay. Проверки
IPv4/IPv6 также воспроизводят потерю адреса после замены Router. Это доказанный
дефект, согласующийся с двумя физическими ошибками1.0.79; полного packet trace
старой ошибки телефона нет, поэтому единственная причина всех TLS-ошибок
не утверждается.

Только Android теперь сохраняет таблицу идентичностей на время процесса.
Текущий Router заново проверяет срок, подписанную политику и её версию;
отзыв политики по-прежнему запрещает DIRECT. Исключение API остаётся строго
для двух first-party hostnames и TCP443 с квалифицированной физической сетью.
Лимит8192 записей, TTL до5мин и запрет повторного назначения идентичности
сохранены. Кэш только в памяти. Сроки остальных платформ не менялись.
TLS trust, scope DIRECT, таймауты и повторные попытки не расширялись.

## Проверка исходника

- RED: прежние source-файлы дают EOF в HTTPS и теряют cached A/AAAA.
- GREEN: полный `go test -race ./...` и `npm run check` прошли.
- На самом Mi A1 выполнены ARM64 тесты HTTPS после замены peer, IPv4/IPv6,
  текущей политики, её отзыва и expiry. Временный binary удалён.
- Регрессии используют синтетический peer/проверяемый тестовый CA; host OS
  TUN, listeners, маршруты и DNS settings не создаются.

## Подписанный кандидат

Android 1.0.80/build88/code1008088/runtime1.0.80; версия iOS не менялась.
Source `07058bc912a2c523d79908548047496c723821cd`,
tree `1799b429665619ad18d1b6868b49b346741041cf`,
workflow `55704471f438f358fbc5d06b0f5d45412858c907`.
[CI40069947095](https://github.com/ibotpafos/vex-client/actions/runs/40069947095)
успешно завершил quality, Go race, native JVM, сборку, оба upload и signing cleanup.

ZIP digests/bytes/CRC, receipt source/tree/run/workflow, ожидаемый signer,
ARM64/ARMv7, manifest, runtime, JNI и R8 сверены. Новые Go libraries отличаются
от фактически установленного1.0.79 в обеих ABI. Совместимость обновления
проверена с извлечёнными байтами1.0.79. Установка поверх него сохранила
first-install, данные и системные предпочтения; установленный APK повторно
извлечён и совпал по SHA256.

APK:44 011 131 bytes,
SHA256 `7619f466b940fe9b297a1e7844804fdfe23e0567c2abe11bf6a5cbbabfb7b382`.
R8 SHA256 `3f6349de713faf9e28c87e9edf40a70c6b47d97f4d494c3bbfb2dbf14b7d8a77`.

## Физическая приёмка

После обновления выполнена перезагрузка стенда с VPNoff и исходными null
Always-on/lockdown. Cold start сохранил login/Noord и настройки. Для тестовой
UI-оснастки потребовалась эта перезагрузка: до неё accessibility root временами
был null; незавершённые чтения не считаются успехом и не отправляли input.

| Сценарий | Проверенный результат |
| --- | --- |
| Первое NL после cold start | Native proof495мс, peer/endpoint NL,4/4 ordinary UID DNS/HTTPS/STUN |
| Пять NL→DE и пять DE→NL |10/10 приняты,10 новых peer UUID, нужные UAPI/endpoint и egress,40/40 сетевых успехов |
| Подтверждение выбранного peer |355–511мс; proof записан до выборочного кадра «Подключено» |
| Сохранение контекста | Wi-Fi Network100 и VPN Network101 на всей серии, без перезапуска app/сброса underlay |

Ни одного API TLS rollback/error в наблюдаемых кадрах серии. Проверки не
очищали DNS/connection cache между переходами. Пакетный regression отдельно
воспроизводит старый EOF; наблюдаемая физическая серия подтверждает исправленный
пользовательский сценарий, не все возможные причины TLS ошибок.

Wi-FiOFF10.442с оставил только VPN Network и отозвал «Подключено» в четырёх
выборочных кадрах. После возврата — network generation4, новый native proof344мс
и4/4 проб через NL. Screen-off12с/Dozing/wake дал4/4 через NL и вернул Awake;
deviceidle былACTIVE, глубокий Doze/kernel suspend не утверждаются.

При cleanup legacy UI-оснастка снова вернула null root; это чтение исключено.
Настройки и возврат к Noord/VPNoff подтверждены отдельными screenshots и ADB
snapshot. Перезагрузка не устранила нестабильность оснастки полностью;
при неполученном дереве автоматический input не выполнялся.

Стенд возвращён в allapps/selected0, auto-connectOFF/auto-serverOFF, Noord/VPNoff.
Null Always-on/lockdown, Wi-Fi/data/airplane/timeout и Awake совпали с baseline;
first-install/login сохранены. Owned QA package, JAR/XML, два собственного
OAT companion basename, пустые owned dirs и тестовый ключ удалены. Read-only
Mac DNS и NC hashes совпали до/после. Scope закрыт, replay запрещён. VEX 1.0.80, INCY 3.8.1 и официальный Instagram
остаются установленными; production release нет.

Предыдущая защита boot/lockdown описана в [приёмке1.0.78](android-recovery-boot-20261023.md).
Этот проход проверил cold start с VPNoff; защищённый pre-unlock boot повторно
не квалифицировался. Нет квалифицированного LTE/physical IPv6 uplink или FBE
до unlock. UI/трафик выборочные, не запись каждого frame/packet.

## Независимая проверка INCY

INCY 3.8.1 использует собственное ядро и не получает это исправление VEX.
Профиль «Автоматически» на стенде дал FI egress и4/4 успеха DNS/HTTPS/STUN;
Instagram Web200, API/CDN ответы с проверенным TLS. Это конкретная подписка
и наблюдаемый выход, не обещание автоматического runtime failover.

Включённый встроенный Kill Switch INCY не удержал блокировку после force-stop:
при сохранённом Wi-Fi DNS и два HTTPS контроля прошли напрямую. Затем через
Android Settings для INCY включены «Не отключаться от VPN» и «Блокировать
соединения без VPN». После force-stop все четыре пробы заблокированы, Wi-Fi
остался доступным. При работающем INCY тот же UID дал4/4 через FI, после
снятия системной защиты DNS/HTTPS снова прошли напрямую. STUN в прямой сети
сам по себе не был рабочим отрицательным oracle.

Для защиты от этого сценария на Android проверены именно системные Always-on
и lockdown. Встроенный переключатель приложения их автоматически не включает.
Это наблюдение Mi A1/Android9; оно не устанавливает поведение iPhone.
Системные flags возвращены к исходным null, настройки INCY и Noord/VPNoff
восстановлены; profile routing не менялся.

Официальный Instagram 451.0.0.53.80 установлен из Google Play и запущен через
INCY/NL после4/4 обычных сетевых проб. Приложение дошло до welcome screen;
происхождение welcome assets из сети не доказано. Вход, лента и Reels/video
не выполнялись. iPhone остаётся отдельной непроведённой приёмкой.

Private evidence и исходники оснастки:
`/Volumes/D/Codex Storage/evidence/vpn-control-api-20261024/`.
Все development artifacts/caches находятся наD; временные Android-файлы
принадлежат платформенному хранилищу стенда.
