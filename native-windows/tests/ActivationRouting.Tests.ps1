param([switch]$FixtureProcess)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $FixtureProcess) {
    # Platform doubles live only in this child; never replace loaded WinUI or
    # AppLifecycle types in another test or in an installed application.
    & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $PSCommandPath -FixtureProcess
    if ($LASTEXITCODE -ne 0) { throw 'Actual-source activation routing checks failed.' }
    return
}

$sources = @(
    (Join-Path $PSScriptRoot '../src/Vex.Windows.App/Program.cs'),
    (Join-Path $PSScriptRoot '../src/Vex.Windows.App/App.xaml.cs'),
    (Join-Path $PSScriptRoot '../src/Vex.Windows.Client/Auth/ProtocolActivationUriParser.cs'),
    (Join-Path $PSScriptRoot '../src/Vex.Windows.Client/Auth/AuthActivationTrace.cs'),
    (Join-Path $PSScriptRoot 'fixtures/ActivationRoutingFixture.cs')
)
# Compile all three production files verbatim. The fixture supplies only inert
# platform/UI/services: no native activation, account, storage, VPN or network.
Add-Type -Path $sources -CompilerOptions @('/nullable:enable')
$scenarios = [Vex.Windows.App.ActivationRoutingFixture]::Run()
Write-Host "PASS actual-source activation routing: $scenarios cold, startup, warm and preview scenarios."
