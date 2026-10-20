# macOS 0.1.91/121 — исправление запуска, 20 октября 2026

Опубликован в 15:55 МСК через штатный immutable publisher.
[Релиз](https://github.com/ibotpafos/vex-client/releases/tag/macos-v0.1.91),
source `03c61742da6dd64bbaf75370ebda2195a30499fe`,
[public run39424953867](https://github.com/ibotpafos/vex-client/actions/runs/39424953867).
Исправление принято в [PR133](https://github.com/ibotpafos/vex-client/pull/133),
GUI installer — в [PR132](https://github.com/ibotpafos/vex-client/pull/132),
MCP workflow — в [PR1018](https://github.com/ibotpafos/VPN/pull/1018).

## Причина и исправление

Присланный отчёт относится к0.1.87/126 из `/Applications/VEX Native.app`.
В домашней папке уже была0.1.90/120. В обеих копиях каталог237 стран цел и
совпадает с исходниками. Карта вызывала генерируемый SwiftPM `Bundle.module`:
его accessor мог завершить процесс, поскольку packaged bundle находится в
`Contents/Resources`, а build directory отсутствует на компьютере пользователя.
Изображения уже использовали optional resolver; теперь он общий и для карты.
Недоступный или повреждённый каталог оставляет пустую фигуру.

Первый full CI выявил отдельный XCTest host: ресурсы лежат рядом с загруженным
тестовым bundle. Добавлены Foundation marker и actual SwiftPM XCTest fixture.
Final [CI39423052681](https://github.com/ibotpafos/vex-client/actions/runs/39423052681)
принял все8 resource cases, full native319/0 failures, shared и Android.
CodeQL и portable release contracts PASS. Локально7 cases PASS, XCTest SKIP:
на хосте только Command Line Tools. App-root-only negative control отклонён.
Оба release builder path проверяют реальные packaged/relocated/missing-resource
layouts; production preflight требует country catalog.

## Проверенная доставка

[Candidate39423816693](https://github.com/ibotpafos/vex-client/actions/runs/39423816693)
и [publisher dry-run39423734953](https://github.com/ibotpafos/vex-client/actions/runs/39423734953)
PASS. Candidate provenance связывает client03c61742 и VPN4c9c767f2.
Независимо проверены outer digest, шесть файлов, Ed25519, версии/ключ bundle,
четыре universal Mach-O, русский appcast; локально — nested all-architecture
codesign strict и certificate pin. Существующие ключи сохранены.

Public acceptance в15:56 МСК: все шесть asset digests, immutable source/tag,
Ed25519 обеих public appcast, update API от0.1.88 и latest download PASS.
Фактический bundle содержит прежний Sparkle key и проверку до extraction.
Опубликованный ZIP:15815887 bytes, SHA-256
`94c411826fb7470830c519d5ca2371d22c71a7b5dc98d1282a81b64ca3a8a2d0`.
Candidate ZIP имеет другой digest; установщик использует именно public bytes.

MCP release truth видит обе ленты0.1.91/121 и успешный public health/download.
Его общий `watch` сохраняет известный backend local/production drift,
ограничение signature-presence и непроверенный legacy bridge fallback.
Криптография дополнительно проверена независимо; physical installation и
legacy failure-path acceptance этим проходом не заявляются.

## GUI установщик

MCP exact-plan/build создал `VEXVPN-0.1.91-121-Installer.pkg` из public ZIP,
сохранив подпись app. Пакет:15734245 bytes, SHA-256
`3abcfc4d90f3bb11562aeecf07d484c6db0b000a760a895e4c778b590364481f`.
Независимый `pkgutil --expand-full`: все113 файлов и ссылок совпадают с ZIP,
nested codesign/all architectures/pinned requirements PASS. Installer metadata
и choices подтверждают current-user domain; target `~/Applications/VEX Native.app`.
Пакет устанавливает app без запуска, root helper или сетевых действий;
установка поверх запущенного приложения отклоняется. Локальный `.pkg` передан
владельцу; отдельная публичная публикация `.pkg` не выполнялась.

Self-signed app, unsigned PKG, без Developer ID/notarization. Первоначальный
Open Anyway для PKG возможен; универсальное одно подтверждение не проверено.
Clean-guest GUI/first-open остаётся TODO у builder evidence flags.
Real tunnel, physical upgrade/rollback и новый DIRECT не приняты этим проходом.

Обе установленные копии сохранили executable hashes/version, OS VPN connected1.
Agent не устанавливал/запускал app и не менял helper/routes/DNS/PF/quarantine/trust.
Все новые development outputs/caches — на D, fixed disk reserves сохранены.

## Новость и продолжение

В15:57 МСК опубликована [новость](https://vexguard.app/news/news_8f48d1fd1b06d1fd1fd020a0bd0e2115)
под standing owner authorization, source `release:macos:macos-v0.1.91`, revision1.
Public article, feed и news sitemap проверены. Account feed общий; auth UI
не открывался. Далее — изолированная GUI-приёмка загруженного PKG/первого
запуска до заявления о поведении на чистом Mac.

Приватные receipts и пакет:
`/Volumes/D/Codex Storage/evidence/macos-resource-startup-20261020/`.
