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

Это граница одного transport exchange. Более высокие profile/legacy fallback,
queue recovery, reconnect и user retry остаются отдельными решениями. В
частности JS preparedTunnel сохраняет legacy fallback для non-mobile callers;
он не квалифицирован этим change как remote exactly-once. Полную mixed/native
ownership matrix ещё нужно завершить.

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
