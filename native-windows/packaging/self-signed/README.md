# Windows: самоподписанный VEX

Сертификат `CN=VEX VPN Self-Signed Native` подписывает установщик, приложение,
службу, маршрутизатор, MSIX и установочные PowerShell-скрипты. Его SHA-256:

`74A7015F870A4E50654796E8DE46C9D213065C9BF616018F0C94D3F5A3D9E0A0`

Сертификат ограничен подписью кода и не может выпускать другие сертификаты.
Закрытый ключ не входит в приложение или архив. Подписи драйвера Wintun и
официального AmneziaWG сохраняются. macOS для этого способа не изменяется.

## Первоначальная установка доверия

Откройте Windows PowerShell **от имени администратора** в распакованном каталоге.
Сверьте отпечаток из этого документа с опубликованным VEX отпечатком и выполните:

```powershell
$pin = '74A7015F870A4E50654796E8DE46C9D213065C9BF616018F0C94D3F5A3D9E0A0'
if ((Get-FileHash -LiteralPath .\VEX-Windows-SelfSigned.cer -Algorithm SHA256).Hash -ne $pin) { throw 'Сертификат не совпадает' }
Import-Certificate -FilePath .\VEX-Windows-SelfSigned.cer -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath .\VEX-Windows-SelfSigned.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Import-Certificate -FilePath .\VEX-Windows-SelfSigned.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

После этого запустите `VEX.Setup.x64.exe` или `VEX.Setup.arm64.exe` из каталога
с полным комплектом соответствующей архитектуры. Установщик проверяет подписи,
отпечаток и хеши файлов перед установкой службы. Для последующих обновлений,
подписанных этим же сертификатом, повторная установка доверия не нужна.

Самоподписанный сертификат требует этого шага на каждом новом Windows-устройстве.
Он не даёт публичного доверия Microsoft или репутации SmartScreen; предупреждение
SmartScreen может сохраняться. Проверки подписей и защита от утечек не отключаются.

## Проверка и удаление доверия

`manage-self-signed-trust.ps1` принимает только публичный сертификат с указанным
SHA-256 и явное действие `Install`, `Verify` или `Remove`. После удаления VEX
можно удалить доверие этому сертификату:

```powershell
.\manage-self-signed-trust.ps1 -CertificatePath .\VEX-Windows-SelfSigned.cer -ExpectedCertificateSha256 $pin -Action Remove
```

## Сборка

Ручной запуск `Native Windows CI`: `self_signed_candidate=true`,
`package_release=false`, `release_version=1.0.68.1`. Ключи берутся только из
отдельного environment `windows-self-signed-candidate`, ограниченного разрешёнными
ветками. Задания pull request их не получают. Эта сборка использует отдельную
идентичность `VEX.Native.SelfSigned` и не заменяет существующие stable-пакеты.
Манифесты создаются локально с rollout 0; публикация пользователям выполняется
отдельно после проверки реального туннеля.

Microsoft: [подпись PowerShell](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing),
[доверие MSIX](https://learn.microsoft.com/en-us/windows/msix/package/create-certificate-package-signing).
