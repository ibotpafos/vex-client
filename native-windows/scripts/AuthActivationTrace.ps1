# Fixed provider and stage metadata only. Raw ETL is never an uploaded artifact.
$script:AuthTraceProvider = [Guid]'5474fab7-6d97-488e-b40f-84ba10c8c1d9'
$script:WindowsTraceStageNames = @{}

function Get-WindowsTraceStageNames {
    param([switch]$Startup)
    $kind = if ($Startup) { 'startup' } else { 'auth' }
    if ($script:WindowsTraceStageNames.ContainsKey($kind)) { return $script:WindowsTraceStageNames[$kind] }
    $typeName = if ($Startup) { 'Vex.Windows.Client.Auth.AppStartupStage' } else { 'Vex.Windows.Client.Auth.AuthActivationStage' }
    $stageType = $typeName -as [type]
    if ($null -ne $stageType) {
        # The native fixture compiles the producer itself. QA bundles instead
        # ask the locked reader, which links that same compiler-owned source.
        $catalog = [pscustomobject]@{
            schema = 'vex.windows-stage-catalog.v1'; provider_guid = $script:AuthTraceProvider.ToString(); kind = $kind
            stages = @([Enum]::GetValues($stageType) | ForEach-Object { [pscustomobject]@{ id = [int]$_; name = $_.ToString() } })
        }
    } else {
        $mode = if ($Startup) { '--startup-stage-catalog' } else { '--stage-catalog' }
        $catalog = (Invoke-WindowsAuthTraceReader -Arguments @($mode)) | ConvertFrom-Json
    }
    $fields = @($catalog.PSObject.Properties.Name)
    if ($fields.Count -ne 4 -or 'schema' -cnotin $fields -or 'provider_guid' -cnotin $fields -or
        'kind' -cnotin $fields -or 'stages' -cnotin $fields -or
        $catalog.schema -cne 'vex.windows-stage-catalog.v1' -or $catalog.kind -cne $kind -or
        $catalog.provider_guid -cne $script:AuthTraceProvider.ToString() -or
        $catalog.stages -isnot [array] -or $catalog.stages.Count -lt 1 -or $catalog.stages.Count -gt 128) {
        throw 'The fixed trace stage catalog is invalid.'
    }
    $names = [Collections.Generic.List[string]]::new()
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $catalog.stages) {
        $fields = @($entry.PSObject.Properties.Name)
        if ($fields.Count -ne 2 -or 'id' -cnotin $fields -or 'name' -cnotin $fields -or
            ($entry.id -isnot [int] -and $entry.id -isnot [long]) -or $entry.id -ne ($names.Count + 1) -or
            $entry.name -isnot [string] -or $entry.name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,63}$' -or
            -not $unique.Add($entry.name)) { throw 'The fixed trace stage catalog is invalid.' }
        $names.Add($entry.name)
    }
    $script:WindowsTraceStageNames[$kind] = $names.ToArray()
    return $script:WindowsTraceStageNames[$kind]
}

function Invoke-WindowsAuthLogman([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::GetFolderPath('Windows')) 'System32/logman.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::new(); $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw 'Authentication trace control did not start.' }
        $output = $child.StandardOutput.ReadToEndAsync(); $errorOutput = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(10000)) { $child.Kill($true); throw 'Authentication trace control exceeded its deadline.' }
        if ($child.ExitCode -ne 0) { throw 'Authentication trace control did not complete.' }
        $null = $output.GetAwaiter().GetResult(); $null = $errorOutput.GetAwaiter().GetResult()
    } finally { $child.Dispose() }
}

function Start-WindowsAuthTrace {
    param([Parameter(Mandatory = $true)][switch]$DisposableRunner)
    Assert-AcceptanceRunner ([bool]$DisposableRunner)
    $reader = Join-Path $PSScriptRoot 'Vex.Windows.AuthTrace/bin/Release/net10.0/Vex.Windows.AuthTrace.dll'
    if (-not (Test-Path -LiteralPath $reader -PathType Leaf)) { throw 'Build the locked authentication trace reader before supplying a tester identity.' }
    $root = Assert-AcceptanceRegularPath -Path $env:RUNNER_TEMP -Directory
    $name = 'VexAuth-' + [Guid]::NewGuid().ToString('N')
    $directory = Join-Path $root $name
    if (Test-Path -LiteralPath $directory) { throw 'Authentication trace ownership is already claimed.' }
    $null = [IO.Directory]::CreateDirectory($directory)
    $null = Assert-AcceptanceRegularPath -Path $directory -Directory
    $marker = Join-Path $directory 'owner.json'
    $stream = [IO.FileStream]::new($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ schema = 'vex.windows-auth-trace-owner.v1'; name = $name } | ConvertTo-Json -Compress))
        $stream.Write($bytes); $stream.Flush($true)
    } finally { $stream.Dispose() }
    $state = [pscustomobject]@{ Name = $name; Directory = $directory; Path = (Join-Path $directory 'activation.etl'); Marker = $marker }
    try {
        Invoke-WindowsAuthLogman @('create', 'trace', $name, '-ets', '-p', $script:AuthTraceProvider.ToString('B'), '0xffffffffffffffff', '5',
            '-o', $state.Path, '-f', 'bincirc', '-max', '8', '-nb', '2', '8', '-bs', '64')
    } catch {
        # Even a lost start acknowledgement belongs to this reserved name.
        # Do not replay start or stop any other system trace.
        try { Invoke-WindowsAuthLogman @('stop', $name, '-ets') } catch { }
        throw 'The owned authentication trace could not be started; no start replay is allowed.'
    }
    return $state
}

function Convert-WindowsAuthTraceEvents {
    param([object[]]$Events)
    return Convert-WindowsTraceEvents -Events $Events
}

function Convert-WindowsStartupTraceEvents {
    param([object[]]$Events)
    return Convert-WindowsTraceEvents -Events $Events -Startup
}

function Convert-WindowsTraceEvents {
    param([object[]]$Events, [switch]$Startup)
    if ($Events.Count -gt 256) { throw 'Authentication trace exceeded its event budget.' }
    $stages = @(Get-WindowsTraceStageNames -Startup:$Startup)
    $primary = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $secondary = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($event in $Events) {
        $names = @($event.PSObject.Properties.Name)
        if ($names.Count -ne 2 -or 'Stage' -cnotin $names -or 'Primary' -cnotin $names -or $event.Primary -isnot [bool] -or
            ($event.Stage -isnot [int] -and $event.Stage -isnot [long])) { throw 'Authentication trace stage format is invalid.' }
        $stage = [long]$event.Stage
        if ($stage -lt 1 -or $stage -gt $stages.Count) { throw 'Authentication trace stage is outside its allowlist.' }
        if ($event.Primary) { $null = $primary.Add($stages[$stage - 1]) }
        else { $null = $secondary.Add($stages[$stage - 1]) }
    }
    $schema = if ($Startup) { 'vex.windows-startup-trace.v1' } else { 'vex.windows-auth-trace.v1' }
    return [ordered]@{ schema = $schema; available = $true; stage_payload_only = $true;
        primary_stages = @($primary | Sort-Object); secondary_stages = @($secondary | Sort-Object) }
}

function Invoke-WindowsAuthTraceReader {
    param([string[]]$Arguments)
    $reader = Join-Path $PSScriptRoot 'Vex.Windows.AuthTrace/bin/Release/net10.0/Vex.Windows.AuthTrace.dll'
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command dotnet -CommandType Application).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @($reader) + $Arguments) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::new(); $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw 'Authentication trace reader did not start.' }
        $output = $child.StandardOutput.ReadToEndAsync(); $errors = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(15000)) { $child.Kill($true); throw 'Authentication trace reader exceeded its deadline.' }
        $raw = $output.GetAwaiter().GetResult(); $null = $errors.GetAwaiter().GetResult()
        if ($child.ExitCode -ne 0 -or [Text.Encoding]::UTF8.GetByteCount($raw) -gt 64KB) { throw 'Authentication trace reader did not complete within its output contract.' }
        return $raw
    } finally { $child.Dispose() }
}

function Read-WindowsAuthTraceProjection {
    param([string]$Path, [int]$PrimaryProcessId, [switch]$Startup)
    $arguments = @('--etl', $Path, '--primary-pid', [string]$PrimaryProcessId)
    if ($Startup) { $arguments += '--startup' }
    return Invoke-WindowsAuthTraceReader -Arguments $arguments
}

function Stop-WindowsAuthTrace {
    param([Parameter(Mandatory = $true)]$State, [int]$PrimaryProcessId, [switch]$Startup)
    $root = Assert-AcceptanceRegularPath -Path $env:RUNNER_TEMP -Directory
    if ($State.Name -cnotmatch '^VexAuth-[a-f0-9]{32}$' -or $State.Directory -cne (Join-Path $root $State.Name) -or
        $State.Marker -cne (Join-Path $State.Directory 'owner.json') -or $State.Path -cne (Join-Path $State.Directory 'activation.etl')) {
        throw 'Authentication trace cleanup ownership is invalid.'
    }
    $null = Assert-AcceptanceRegularPath -Path $State.Marker
    if ((Get-Item -LiteralPath $State.Marker).Length -gt 256) { throw 'Authentication trace owner metadata is too large.' }
    $owner = [IO.File]::ReadAllText($State.Marker) | ConvertFrom-Json
    if ($owner.schema -cne 'vex.windows-auth-trace-owner.v1' -or $owner.name -cne $State.Name) { throw 'Authentication trace owner metadata changed.' }
    Invoke-WindowsAuthLogman @('stop', $State.Name, '-ets')
    $null = Assert-AcceptanceRegularPath -Path $State.Path
    $size = (Get-Item -LiteralPath $State.Path).Length
    if ($size -le 0 -or $size -gt 9MB) { throw 'Authentication trace file is outside its fixed budget.' }
    try {
        # TraceEvent decodes self-describing EventSource metadata directly;
        # Get-WinEvent cannot reliably decode this provider without installing
        # global event manifests. The separate QA reader never ships in VEX.
        $raw = Read-WindowsAuthTraceProjection -Path $State.Path -PrimaryProcessId $PrimaryProcessId -Startup:$Startup
        $decoded = $raw | ConvertFrom-Json
        $schema = if ($Startup) { 'vex.windows-startup-stage-projection.v1' } else { 'vex.windows-auth-stage-projection.v1' }
        if ($decoded.schema -cne $schema) { throw 'Authentication trace reader returned an unknown schema.' }
        if ($Startup) { return Convert-WindowsStartupTraceEvents -Events @($decoded.events) }
        return Convert-WindowsAuthTraceEvents -Events @($decoded.events)
    } finally {
        # Only this validated session's three paths are removable. Preserve
        # unexpected siblings instead of broad recursive cleanup.
        Remove-Item -LiteralPath $State.Path -Force
        Remove-Item -LiteralPath $State.Marker -Force
        if (@(Get-ChildItem -LiteralPath $State.Directory -Force).Count -eq 0) { Remove-Item -LiteralPath $State.Directory }
    }
}
