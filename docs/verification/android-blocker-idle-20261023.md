# Android: устранение загрузки CPU в сервисе блокировки

23 октября 2026, Москва. Выделенный владельцем Mi A1, Android9/API28, arm64.
Активный VPN владельца и сеть Mac исключены из команд изменения. Сервера и
XorekCloud в этом цикле не меняются. Публикация и OTA не выполняются.

## Причина и исправление

`VexLeakBlockerService` читал неблокирующий TUN в непрерывном цикле. При EAGAIN
Android `IoBridge.read` возвращает0, цикл немедленно повторялся. Это проверено
по [исходнику Android9](https://android.googlesource.com/platform/libcore/+/android-9.0.0_r1/luni/src/main/java/libcore/io/IoBridge.java).
Для blackhole сохранён открытый TUN с маршрутами IPv4/IPv6 и явным DNS; чтение
и пересылка пакетов отсутствуют. Удалены поток и второй закрывающий дескриптор
объект. Остановка по-прежнему закрывает единственный ParcelFileDescriptor.

Исходник исправления `ef8e53330e248fa25f97d1fe82da75b4d291da9a`,
tree `5703d0dfb607f2ae936272fd1d4252366c11f745`.
Android candidate1.0.75/build83/code1007583/runtime1.0.75. Зависимости не менялись.

## Проверка настоящего Android-компонента

В отдельный test-signed APK с другим package/UID скомпилирован точный исходный
Kotlin-класс сервиса до и после изменения. MainActivity/ContextCompat — узкие
test-shims; для coroutine linkage использованы cached stdlib2.1.20 и
coroutines1.8.1, suspend startAndAwait/stopAndAwait этим fixture не проверяются.
Production dependencies остаются прежними. Все APK/сборки/временные файлы на D;
классы компонента работают на физическом Android, mock TUN не применяется.

| 12-секундный idle-замер процесса | До | После |
| --- | --- | --- |
| CPU относительно одного ядра | 100,76% | 0,27% |
| Active TUN | да | да |
| Поток vex-leak-blocker | присутствует | отсутствует |

После десяти циклов и нагрузки повторный idle-замер дал0,28%; FD snapshots
оставались в диапазоне61–64. Это короткий CPU-замер всего процесса, не измерение ватт/времени работы батареи.
Старый исходник отдельно отвергнут обновлённым source-contract; исправленный
прошёл. Полный npm run check PASS, после синхронизации версии focused release
checks PASS. Это дополнительно к измерению настоящего компонента.

Отдельный обычный UID-наблюдатель не применяет protect/bind/root. Исключённый
UID тестового VPN одновременно служит положительным контролем физической сети:

| Проба | Контроль без захвата | Обычный UID под захватом |
| --- | --- | --- |
| HTTPS IPv4 | HTTP200 | ответа нет до15с |
| TCP1.1.1.1:443 без DNS | соединение0,14с | timeout3,12с |
| UDP DNS8.8.8.8 | валидный ответ | timeout |

Нагрузочный fixture передал ядру10000 UDP-пакетов по1200байт в TEST-NET
адрес192.0.2.1:9 через захват, за8,0с. PSS процесса39345 →39322KiB
по Android meminfo; это не измерение kernel queue memory. После UDP-нагрузки HTTPS/DNS остаются заблокированы при рабочем контроле.
При displayOFF/Dozing после30,15с и во время явно запущенного foreground
наблюдателя VPN сохранялся, успешных HTTPS/DNS ответов не было. Экран возвращён
вON/Awake. Deep Doze и kernel suspend этим прогоном не измерены.
Десять STOP→START циклов подтвердили исчезновение/возврат VPN на каждом шаге
без замены процесса. STUN напрямую не отвечает ещё до теста, поэтому его
отрицательные результаты не засчитываются как доказательство защиты.

## Границы и продолжение

Это приёмка компонента fallback-блокировки на живом Wi-Fi uplink; она не
подменяет вызов protected-stop всего production APK и не доказывает физический
IPv6/LTE handoff. Эти uplink на стенде отсутствуют. DNS resolver egress в стабильном connected состоянии проверен отдельно
ниже; reconfiguration/Private DNS и boot этим не квалифицированы. Системные Always-on/lockdown остаются неподдержанными: безопасный
boot требует native headless restore, сохранения профиля и согласованного
жизненного цикла UI/сервиса; простой manifest-флаг этого не даёт. Смотри
[предыдущую матрицу1.0.74](android-network-transition-20261023.md).

Сеанс локальной сборки и npm check прервался при перезагрузке Mac; эти логи
сохранены отдельно и не засчитаны. Полный check и сборка fixture повторены.
Первый queue fixture не достиг10000 пакетов в8с (9767); конечный бюджет
увеличен до12с без изменения packet target. Его исходный failed receipt и
исключённое чтение старого receipt после update сохранены; итоговый прогон
читает только новый файл после очистки fixture-owned результата. Kernel link
counters недоступны shell по permission denied; их значения не предполагаются.
Первый screen-off assert ожидал Asleep, Android сообщил Dozing; повторный
прогон отдельно проверяет displayOFF, сохраняет фактическую wakefulness.
Первый idle-замер до принятия VPN consent показал active=false и также исключён.

Private evidence: `/Volumes/D/Codex Storage/evidence/vpn-android-blocker-20261023/`.
Исходный CPU receipt: before-active-idle.json; исправленный: after-active-idle.json.
Остальные: lifecycle.json, blocked-owner-control.json, blocked-ordinary-uid.json,
post-load-owner.json, post-load-observer.json, queue.json, screen-off.json,
after-cycles-load-idle.json, build-before/artifact.json,
build-after/artifact.json, contract-before.log, contract-after.log, npm-check.log.

## Подписанный клиент1.0.75

[run39877235836](https://github.com/ibotpafos/vex-client/actions/runs/39877235836)
завершилсяsuccess: полный client check, release и native debug unit task.
Orchestration214e1fce8e52bb4aa8fbc612506b72281b24ad48. Source/tree binding,
один ожидаемый production signer, обе ARM ABI, JNI library hashes, embeddedJS,
runtime1.0.75, ZIP CRC, checksum sidecar и R8 provenance проверены независимо.
Публикация/OTA отсутствуют. Старый drain thread literal присутствует в DEX1.0.74
и отсутствует в новом DEX; это дополнение к привязке неизменяемого source.

APK Vex-Android-1.0.75-83.apk,43959831байт, SHA256:
`403b3decc9e2411b5493568c1712927b7d030a33ec3aa096bbc1fa47204b4c3a`.
Signer SHA256:
`cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470`.
R8 mapping SHA256:
`0b141928e57c73271f11983ae7a73c5f4c73a8618feb045d32ff4df9b5e165b0`.

На том же Mi A1 выполнено штатное update1.0.74→1.0.75. Байты установленного
APK совпали с проверенным, first-install timestamp и вход сохранены, выбранная
локация сохранилась. После подключения обычный UID получил три успешные пробы:
HTTPS и STUN имеют один VPN egress, отличный от direct, UDP DNS работает.
Свежий screenshot подтвердил «Подключено / Соединение защищено». Первый UI
snapshot показывал восстановление, затем свежий accessibility tree временно
не удалось снять; положительный статус подтверждён новым screenshot и
независимыми probes, старый XML не использовался для утверждения результата.

Receipts: ci-run.json, candidate-verified.json, signed/signed-candidate-receipt.json,
r8/provenance.json, candidate-verification-tools.json, dex-blocker-regression.json,
client-upgrade.json, candidate-real-vpn.json, client-vpn-acceptance.json,
candidate-current.png. Это дополнение к компонентной приёмке, не полный
production protected-stop; sleep/network/reboot matrix1.0.74 не переименована
в новый полный прогон1.0.75.

## Привязка JNI-пробника к стенду

`scripts/test_android_routing_jni_device.sh` больше не выбирает произвольный
единственный USB-телефон через adb-d. Для прежних запусков требуется миграция:
передать VEX_ANDROID_QA_SERIAL и VEX_ANDROID_QA_MODEL явно, вместе с прежним
VEX_ANDROID_DEVICE_QA=1. Отсутствующий/чужой serial или несовпадающая модель
завершают сценарий с exit2 до записи на устройство. Все последующие команды,
включая cleanup, используют тот же adb-s. Сам serial в вывод не печатается.
TMPDIR обязателен и проверяется по физическому пути на смонтированном D;
Java temporary directory также задан туда. Положительный запуск на разрешённом Mi A1 со старым baseline APK1.0.74
прошёл JNI load/protector/invalid admission, без VPN и с удалением local/remote
fixture. Он проверяет helper, не новый1.0.75 APK. Новые gates проверены отрицательными
запусками missing_identity/wrong_identity/wrong_model, каждый отказал с exit2. Дополнительно отвергнуты TMPDIR внеD и symlink сD
наружу; в обоих случаях exit2 до mktemp.

Пример окружения (значения serial/model оператор берёт у разрешённого стенда):

```sh
export VEX_ANDROID_DEVICE_QA=1
export VEX_ANDROID_QA_SERIAL='<approved-stand-serial>'
export VEX_ANDROID_QA_MODEL='<approved-stand-model>'
export VEX_ANDROID_SDK_ROOT='/opt/homebrew/share/android-commandlinetools'
export VEX_JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
export TMPDIR='/Volumes/D/VEX-CI/cache/local-user/tmp'
bash scripts/test_android_routing_jni_device.sh /absolute/path/to/candidate.apk
```

Пробник загружает реальную библиотеку, проверяет callback descriptor и отказ
неверных входных параметров. Он не открывает TUN и не объявляет packet acceptance.

## Независимый connected DNS egress

Протокол взят из текущего [официального connection check Mullvad](https://mullvad.net/en/check):
config задаёт dns_leak_domain, шесть уникальных имён вызывают авторитетную
проверку, ответ возвращает наблюдавшиеся IP recursive resolvers. Реализация
сохранена как private source snapshot, а не новая dependency клиента.
Отдельный test-signed APK использует обычный UID, InetAddress/system DNS и
HTTPS с проверкой TLS, без protect/bind. Профили и ключи VEX не извлекаются.

Прямой baseline завершился тайм-аутом на config до тестовых запросов. Первый
VPN batch6parallel получил4/6 ответов: resolver совпал с одновременным VPN egress,
два HTTPS-запроса получили timeout. Для раздельного замера DNS добавлен явный
InetAddress lookup и два worker. После одного bootstrap UnknownHost исключённого
из успешных batches повторный прогон дал6/6. DNS179–513мс, полный запрос658–963мс;
все шесть resolver IP совпали с HTTPS в этом же receipt и с одновременно
успешными обычными HTTPS/STUN probes, отличаются от direct egress. Индикатор
mullvad_dns=false ожидаем для VEX и не трактуется как утечка. Это независимая
аттестация этих connected DNS-запросов, не универсальная гарантия при переходах.
Снижение concurrency — изменение стенда; причинность исходных timeout не
доказана и production DNS по этому тесту не перенастраивался.

Сборка дополнительного staged observer сначала истекла на D8/60с; попытка с
JAVA_TOOL_OPTIONS прервана, поскольку SDK wrapper переопределяет heap2GiB.
Явный D8-JXmx256m позволил завершить сборку. Это настройка одного compiler
process, системные параметры Mac не менялись. Старые receipts/APK сохранены;
новый staged APK и свежие tags проверены отдельно, старые файлы не переиспользованы.

Важное наблюдение: ранний HTTPS/STUN/DNS egress соответствуетde-awg3, поздний —
nl-awg3 по конфигурации production inventory. Карточка оставаласьNoord; первый
UI показывал восстановление. В каждом успешном наборе egress был VPN, не direct.
Прямое сопоставление выбранной локации и фактического узла во время recovery
не принято. MCP fallback audit за1ч обработал34/34 reports, rowsfallback0 и
statusinsufficient_evidence; это не подтверждение причины переключения. Дополнен
существующий TODO(android-route-canary) в useVpnConnectionFlow.ts. Нужны paired
native-bound canary и атрибуция recovery; сетевой код вслепую не менялся.

Receipts: dns-direct-baseline.json, dns-candidate-vpn.json,
dns-candidate-vpn-staged.json, dns-candidate-vpn-staged-retry.json,
dns-staged-comparison.json, candidate-post-dns-health.json,
dns-artifact-concurrent6.json, dns-artifact-stage2.json, egress-transition-open.json.

## Завершение стенда

Cleanup PASS: четыре собственных QA APK и тестовый signing key удалены,
временные UI-файлы удалены; отдельного пользователя в этом цикле не создавали.
Остался user0, Wi-Fi/mobile/airplane/always-on/lockdown/timeout соответствуют
началу, экранON/Awake. VPN штатно остановлен через свежий UI, прямые HTTPS/DNS
работают; на стенде оставлен1.0.75, данные VEX не очищались. CLOSED.json
блокирует повторный запуск одноразовых mutation controllers этого evidence run.

Mac DNS и список network connections совпали по хешам с read-only baseline
после внешней перезагрузки. Команды изменения Mac VPN/routes/DNS/PF/services
не выполнялись; совпадение состояния через саму перезагрузку не утверждается.
Receipts: component-cleanup.json, final-direct-after-v75.json, device-final.json,
mac-preservation.json, cleanup.json, CLOSED.json. Signed APK/R8 и исходные
неуспешные попытки сохранены наD. Публикации/OTA и customer news о релизе нет.
