# Повторы запросов VPN-профиля

HTTP method не определяет безопасность повтора. Native profile GET может
назначить узел, восстановить peer и записать evidence; staged GET переводит
prepared→fetched. Legacy config GET тоже может выполнять provisioning.
После dispatch сетевой/HTTP сбой не доказывает отсутствия этих эффектов.

| Producer | Transport attempts | Owner и cancellation | Следующий шаг при неопределённом исходе |
| --- | --- | --- | --- |
| JS requestManagedVpnProfile | 1, existing retryCount:0 | Dispatched profile operation держит queue/deadline; borrower cancellation не освобождает её раньше completion | Existing orchestration получает ошибку и решает recovery отдельно |
| JS fetchStagedDevicePSKProfile | 1 | Session guard до/после HTTP; существующие request deadline и version/digest checks | Existing staged recovery; fetch не ACK и не activation |
| JS preparedTunnelFromDeviceConfig | 1 на config GET; POST token остаётся1 | Прежний caller AbortSignal и session guards сохранены | Ошибка возвращается caller; отмена не подтверждает remote rollback |
| Swift managedVpnProfile | 1 | JSON API/transport сохраняют task cancellation и общий deadline | Existing profile service решает восстановление отдельно |
| Windows GetManagedVpnProfile | 1, SendCoreAsync вызывает HttpClient один раз | Прежний linked deadline покрывает headers/body и caller cancellation | Existing caller policy; Windows code не менялся |
| Обычные JS/Swift GET reads | До3 в прежнем budget | Retry-After, cancellation, error classification прежние | Прежняя bounded retry policy |

Swift transport принимает retryCount с default2 и clamp0…2 для GET; writes
всегда one-attempt, даже с idempotency key. Caller budgets, URL/auth/query,
key material, signing, wire DTOs и storage formats не меняются.

Legacy fallback JS теперь требует отдельного положительного основания. Private
context marker создаётся только при recognized profile-endpoint rejection без
API code:404 с canonical "404 page not found",405 "Method Not Allowed" или501
"Not Implemented" (trim/case normalization), либо при отсутствии локального
web key до dispatch native registration. Generic/malformed/error DTO responses
не дают разрешения на другую выдачу. Ошибки device lookup, регистрации, auth,
entitlement, body/JSON и profile identity возвращаются без legacy/config-token
ветки. Required native clients получают прежнюю исходную ошибку; private marker
не становится публичным error code. Успешный managed web профиль без local key
при старой форме без identity fields остаётся допустимым.

Сохранено прежнее bounded recovery удалённого cache hint: один full owned lookup
после404, включая старые ответы без error code. Это не разрешение на fallback
после произвольной ошибки. Key-epoch recovery, reconnect, queue recovery и user
retry остаются отдельными решениями. Полная mixed/native matrix и remote
exactly-once не установлены этим scoped change.

Regression controls вызывают actual producers через production transport,
подменяя только внешние dependencies. На exact preceding source18 JS controls
показывают3 отправки вместо1; ordinary read control проходит. После исправления
все73 deadline/producer cases проходят. Shared Swift scenario проверяется и в
CLT probe, и в XCTest: preceding source выполняет3 profile отправки, исправленный
код —1; ordinary read по-прежнему восстанавливается. CLT probe19 groups PASS;
новый transport bounds XCTest ждёт macOS CI. Это не physical-device acceptance.


Windows acceptance diagnostics reuse the validator's required check names.
The wrapper emits only fixed stage IDs, boolean cleanup/verdict fields and
known failed/missing check names after its existing cleanup. It never prints
raw JSON, paths, connection details or exception bodies. A bounded diagnostic
read cannot change the original acceptance exit or production/network gates.
Portable PowerShell helper tests cover missing/false/nonboolean evidence and
privacy. A preceding encrypted-tunnel CI failure still needs runtime evidence;
this diagnostic change does not establish a cause or a successful tunnel.


The Windows failure summary now distinguishes HTTPS-control and physical-DNS
prebaseline stages and reports one fixed failure category from a bounded
exception chain. Categories do not expose exception messages/types/addresses,
do not change the acceptance verdict and do not prove a customer incident.
The prior full-physical-baseline failure occurred after TCP prebaseline passed;
HTTPS-control and physical DNS were still indistinguishable in that report.
No TLS/probe timeout, route, DNS, lease, service or cleanup guard was weakened.


Four generated lifecycle request projections now check six actual native payload
producers: connect, disconnect, push token, staged ACK and both key-rotation
producers. Nullable event/push HTTP forms and optional legacy device selectors
are represented in the generated specs; existing native function arguments and
body serialization still produce objects. Event responses remain empty202.
Key rotation retains its existing key/header-or-epoch precondition; staged ACK
uses its version/digest tuple and does not consume an Idempotency-Key header.
The type-only producer changes emit identical JS. Prior generated declarations
and compatibility assertions remain intact.

The latest prior Windows run locates the failure at HTTPS control baseline with
category cancelled and cleanup confirmed. The probe now records parent-token
cancellation, independent8-second budget expiry and an immediate inner timeout
as three boolean observations. Unobserved facts remain null in the safe summary;
strings/numbers are not coerced. These observations do not prove which timer
fired first. The original exception is rethrown;5-second connect and8-second
operation limits, TLS/hostname validation, physical endpoint, lease and cleanup
remain unchanged. Portable helper tests and crossbuilds pass, but this change
does not establish the cause or successful Windows encrypted-tunnel acceptance.
