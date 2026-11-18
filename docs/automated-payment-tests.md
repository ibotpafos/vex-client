# Автотесты Android-продления и оплаты

Из корня клиента, после `npm ci`:

```sh
npm run test:payments
npm run test:unit:all
```

`test:payments` выполняет 19 проверок без Android, OTP, сети и покупок:
состояния подписки/истечения, реальные обработчики кнопок карточки,
адреса продления и поддержки, ошибку открытия браузера и повтор,
защиту от внешнего редиректа, чтение серверного entitlement, отказ и
отсутствие самопроизвольной активации. Тестируются целые исходные модули;
подменяются границы React Native, системного браузера и HTTP.
Это не рендеринг экрана на устройстве и не проверка платёжного провайдера.

`test:unit:all` (macOS/Linux) выполняет каждую группу существующего `test:unit`, даже
если предыдущая упала. Ненулевой exit означает провал хотя бы одной группы;
таймаут группы — 300 секунд, после него завершается вся группа процессов,
включая дочерние npm/tsx. Команды, exit и длительности сохраняются в
`.test-results/unit/results.json`, полный stdout/stderr — рядом.
Этот каталог исключён из Git. Существующие красные проверки не пропускаются.
`test:payments` включён также в обычный `test:unit` и существующий `check`.

Для полной статической проверки остаются `npm run typecheck` и `npm run lint`;
для Android JVM — `npm run test:api-http-jvm` и `:app:testDebugUnitTest` в Gradle.
Эти команды не включаются скрыто в быстрый платёжный прогон.

В этих автотестах нет отправки OTP, ввода настоящих токенов, нажатия оплаты,
изменения подписок, переключения VPN, очистки приложения или публикации APK.
Подтверждение списания, webhook и последующей выдачи доступа требует отдельного
изолированного provider-sandbox E2E; текущий прогон не объявляет их проверенными.


## SDK 58 stability checks

`npm run check` runs the canonical host checks, including actual API/profile modules,
byte-fragment SSE parsing and the isolated Android-inspector safety guards. It does
not establish native decoder or live VPN acceptance. `npm run test:unit:all` runs
all unit groups independently and saves individual failures under `.test-results/unit`.

For a dedicated debug preview connected to its own loopback Metro (8082+), run
`npm run test:android-runtime -- http://127.0.0.1:8082`. The command attaches only to
`com.vexguard.app.sdk58preview`, requires `HermesInternal`, and checks actual native
UTF-8 one-byte/chunked decoding, stream flush/reset and truncated input. It refuses
main/owner QA packages and non-loopback inspectors. It does not install packages,
start Metro, authorize a user, create a payment or connect/disconnect a VPN.
A failing/missing inspector is FAIL, not a skipped or simulated native PASS.
