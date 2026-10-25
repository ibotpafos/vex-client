# Android 1.0.74: изолированная проверка переходов сети

Дата: 23 октября 2026, Москва. Владелец явно выделил Mi A1 под установку,
обновление, переключение сети, сон и перезагрузку. Личный VPN на Mac исключён.

## Артефакт

Кандидат `com.vexguard.app` 1.0.74/build82, versionCode1007482, runtime1.0.74.
Подписан и собран без публикации в
[manual run39865502454](https://github.com/ibotpafos/vex-client/actions/runs/39865502454).
Исходный commit `bba833cffd64cbc0b3cfa210a31b087d4726500d`,
tree `758fc769f237ad55480e28fe99bb1f33a784fe83`,
orchestration `07a2d2e66bd153d3f0772f34326cb929b693d6d2`.
Включено исправление pending DIRECT/recovery dial, DNS и policy refresh из
`5304959fb27de8214eced4fa6422a69dd089ae88`.

APK `Vex-Android-1.0.74-82.apk`, 43960067байт:
`228cf0d15b1124726f0d3f281ad62f58f76087a8c47b3f9343a93ffdb44aff3f`.
Production certificate SHA256:
`cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470`.
R8 mapping SHA256:
`475d5127190652a3af8c3ff79e62858944c4e95f80afa7b51737ef697359c948`.

Независимо проверены source/tree/run binding, совпадение signed/R8 receipts,
байты APK и checksum sidecar, apksigner с одним ожидаемым signer, обе ABI
arm64-v8a/armeabi-v7a и три VPN библиотеки в каждой, embedded JS, runtime в
скомпилированном manifest, ZIP CRC и совместимость с опубликованной1.0.73.
Зависимости не менялись. Полный `npm run check` прошёл локально и в CI;
release build и `:app:testDebugUnitTest` завершились успешно. Отдельно прошли
11 отрицательных fixtures signing workflow. Права, actor/ref/environment gates
не расширялись; существующий manual signing workflow привязан к точному source.

## Физическое устройство

Mi A1, Android9/API28, arm64-v8a. Все ADB-команды адресованы точному разрешённому
устройству. Секреты, профили, токены и данные аккаунта не извлекались.
Обычный отдельный UID-наблюдатель использует HTTPS IPv4, UDP STUN и UDP DNS;
его сокеты не защищаются от VPN и не привязываются к физическому Network.
Без VPN подтверждены рабочие HTTPS/DNS; STUN напрямую не отвечает и сам по себе
не служит отрицательным доказательством. Через1.0.73 и затем1.0.74 HTTPS и STUN
получили один VPN egress, отличный от прямого выхода; DNS разрешается.

| Сценарий | Проверенный результат |
| --- | --- |
| Чистые данные | APK установлен в новый пустой пользовательский профиль Android через install-existing; первый запуск показал онбординг и вход без чужой сессии. Новый вход/VPN в этом профиле не выполнялся. |
| Обновление | Штатное install-r1.0.73/code1007381 →1.0.74/code1007482. Байты установленного APK совпали; first-install timestamp, авторизация, Smart/AntiDetect и настройки автоподключения/автовыбора сохранены. |
| JNI | Из установленного APK загружена реальная библиотека; protector descriptor и отказ неверных параметров прошли. Этот JNI probe явно не объявляет packet acceptance. |
| Потеря/возврат Wi-Fi | Physical Network568 →571; VPN Network570/TUN сохранён. Runtime подтвердил перепривязку сокетов без замены TUN. После возврата первый STUN ещё не ответил, второй набор из трёх проб прошёл; верхняя граница полного восстановления15,3с. Все наблюдавшиеся успешные egress были VPN. UI вернулся в «Подключено / Соединение защищено» без старого DNS-предупреждения. |
| Сон / Doze | Экран OFF, Dozing, IDLE подтверждены спустя96,92с. Все три пробы явно запущенного foreground-наблюдателя прошли при сохранённом IDLE; после пробуждения также прошли с тем же VPN egress. Эмуляция unplug и force-idle сняты. Kernel suspend и произвольные background-приложения этим не измерены. |
| Перезагрузка | Новый boot ID; boot-complete и байты APK подтверждены через50,6с. До открытия VEX процесс/VPN отсутствуют, HTTPS/DNS идут напрямую. После открытия автоподключение без нажатия Connect вернуло VPN: все три пробы прошли не позднее12,11с. Вход, first-install и настройки сохранены. |

При выключенном Wi-Fi физический default network отсутствовал, оба modem data
state оставались0; все три пробы не прошли. Это проверка обрыва/восстановления,
а не доказательство kill-switch при работающем альтернативном uplink.
LTE handoff и физический IPv6 uplink отсутствуют; они не приняты этим прогоном.
После boot до открытия VEX у wlan0 нет global IPv6 адреса и IPv6 default route.
UDP DNS здесь проверяет разрешение и отсутствие успешного ответа при обрыве,
но не является независимой аттестацией egress рекурсивного resolver.

У Android-настройки автоподключения заявлено «при открытии приложения».
Оба VpnService в manifest по-прежнему декларируют SUPPORTS_ALWAYS_ON=false.
Системный lockdown до открытия приложения после boot не заявляется.
Полная матрица pending IPv4/IPv6 TCP/UDP/DNS дополнительно проверена
[59 Go leaf tests / 43 leak scenarios](vpn-leak-scenarios.md); это отдельные
packet fixtures, а не замена физических LTE/IPv6/boot gates.

## Свидетельства и восстановление

Private evidence находится на D:
`/Volumes/D/Codex Storage/evidence/vpn-client-device-acceptance-20261023/`.
Основные receipts: `ci-run.json`, `candidate-verified.json`, `upgrade.json`,
`upgrade-preferences.json`, `fresh-install.json`, `candidate-jni.json`,
`candidate-connect.json`, `network-transition.json`, `network-runtime-events.json`,
`sleep-dwell.json`, `sleep-probe-state.json`, `sleep-wake.json`,
`sleep-acceptance.json`, `reboot-start.json`, `reboot-complete.json`,
`reboot-before-open.json`, `reboot-acceptance.json`,
`physical-ipv6-capability.json`, `preferences-restored.json`, `device-final.json`,
`cleanup.json`. Signed APK, checksum, CI receipt и R8 mapping сохранены.

Первый install в ещё не запущенный новый пользовательский профиль истёк по120с;
Android9 также отверг неподдерживаемый am start-user-w. Эти попытки сохранены
отдельно и не засчитаны как успешные. После запуска нового пользователя его
чистая установка/первый запуск проверены; временный пользователь уже удалён.
При недоступном свежем accessibility tree сценарий останавливает tap и повторяет
снятие tree, не использует устаревший XML. Прерванный turn не оставил force-idle
или эмуляцию питания: восстановление проверено, post-wake probe снят заново.

Cleanup PASS: пробник и его тестовый signing key удалены, собственный каталог
на телефоне удалён, остался только исходный пользователь0. Smart/AntiDetect
включены, autoconnect/автовыбор выключены, все приложения, Wi-Fi/mobile/airplane,
always-on/lockdown и screen timeout соответствуют началу. Эмуляция питания
снята; VPN штатно отключён, исходный прямой egress восстановлен, вход сохранён.
На стенде оставлен проверенный1.0.74; данные VEX не очищались. Это кандидат для
проверенных сценариев Mi A1, с перечисленными границами мобильной leak acceptance.
Публикация, OTA и установка в личный клиент в этом цикле не выполнялись.
