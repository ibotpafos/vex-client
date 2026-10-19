# Fixed provider and stage metadata only. Raw ETL is never an uploaded artifact.
$script:AuthTraceProvider = [Guid]'5474fab7-6d97-488e-b40f-84ba10c8c1d9'
$script:AuthTraceStages = @('ProcessStarted', 'PrimarySelected', 'RedirectStarted', 'RedirectCompleted', 'RedirectFailed',
    'RedirectReceived', 'DispatcherAccepted', 'DispatcherRejected', 'StartupQueued', 'HandlerStarted', 'HandlerNoProtocol',
    'CallbackEntered', 'AuthGateEntered', 'CallbackIgnoredAfterCancellation', 'ChallengeLoaded', 'CallbackRejected',
    'StateMatched', 'ExchangeStarted', 'ExchangeCompleted', 'SessionSaveStarted', 'SessionSaveCompleted', 'AuthSucceeded',
    'AuthFailed', 'HandlerCompleted', 'HandlerFaulted', 'BrowserRequestStarted', 'UiRefreshRequested')

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
    param([object[]]$Events, [int]$PrimaryProcessId)
    if ($Events.Count -gt 256) { throw 'Authentication trace exceeded its event budget.' }
    $primary = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $secondary = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($event in $Events) {
        if ($event.ProviderId -ne $script:AuthTraceProvider) { continue }
        if ($event.Properties.Count -ne 1 -or $event.Properties[0].Value -isnot [int]) { throw 'Authentication trace stage format is invalid.' }
        $stage = [int]$event.Properties[0].Value
        if ($stage -lt 1 -or $stage -gt $script:AuthTraceStages.Count) { throw 'Authentication trace stage is outside its allowlist.' }
        if ($event.ProcessId -eq $PrimaryProcessId) { $null = $primary.Add($script:AuthTraceStages[$stage - 1]) }
        else { $null = $secondary.Add($script:AuthTraceStages[$stage - 1]) }
    }
    return [ordered]@{ schema = 'vex.windows-auth-trace.v1'; available = $true; stage_payload_only = $true;
        primary_stages = @($primary | Sort-Object); secondary_stages = @($secondary | Sort-Object) }
}

function Stop-WindowsAuthTrace {
    param([Parameter(Mandatory = $true)]$State, [int]$PrimaryProcessId)
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
        $events = @(Get-WinEvent -Path $State.Path -Oldest -MaxEvents 257 -ErrorAction Stop)
        return Convert-WindowsAuthTraceEvents -Events $events -PrimaryProcessId $PrimaryProcessId
    } finally {
        # Only this validated session's three paths are removable. Preserve
        # unexpected siblings instead of broad recursive cleanup.
        Remove-Item -LiteralPath $State.Path -Force
        Remove-Item -LiteralPath $State.Marker -Force
        if (@(Get-ChildItem -LiteralPath $State.Directory -Force).Count -eq 0) { Remove-Item -LiteralPath $State.Directory }
    }
}
