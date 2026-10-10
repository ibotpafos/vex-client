[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApplicationPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [ValidateRange(3, 30)][int]$ObserveSeconds = 10,
    [switch]$DesktopChecks,
    [ValidateSet('signed-out', 'fixtures')][string]$PreviewMode,
    [string]$ScreenshotDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'WinUI application startup smoke requires Windows.'
}
if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Leaf)) {
    throw 'Published WinUI application is missing.'
}
$ApplicationPath = (Resolve-Path -LiteralPath $ApplicationPath).ProviderPath
if ($DesktopChecks -and [string]::IsNullOrEmpty($PreviewMode)) {
    throw 'Desktop checks require an isolated Debug UI preview mode.'
}
if (-not $DesktopChecks -and -not [string]::IsNullOrEmpty($PreviewMode)) {
    throw 'Preview mode requires desktop checks; Release startup runs without preview arguments.'
}
# This check is for a clean hosted build machine, not an installed VPN user.
if (Get-Service -Name 'VEX VPN Service', 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue) {
    throw 'Startup smoke requires a host without an installed VEX VPN service.'
}
if (Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue) {
    throw 'Startup smoke requires a host without a running VEX application.'
}
$sessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VEX/VPN/client-state.bin'
if (Test-Path -LiteralPath $sessionPath) {
    throw 'Startup smoke requires a fresh profile without a saved VEX session.'
}
$previewProtocolKey = 'Registry::HKEY_CURRENT_USER\Software\Classes\vexguard-ui-preview'
if ($DesktopChecks -and (Test-Path -LiteralPath $previewProtocolKey)) {
    throw 'Desktop smoke requires a profile without a previously registered UI preview protocol.'
}

$startedAt = [DateTime]::UtcNow
$process = $null
$ownedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$previousDpiContext = [System.IntPtr]::Zero
$originalCursorPosition = $null
$protocolDiagnosticPath = $null
$protocolDiagnosticHash = $null
$trayDiagnosticPath = $null
$trayDiagnosticHash = $null
$windowHandle = [System.IntPtr]::Zero
$previewArguments = if ($PreviewMode -eq 'signed-out') {
    '--signed-out-ui-preview'
}
else {
    '--focus-pulse-ui-preview'
}
$result = [ordered]@{
    schema = 'vex.windows-startup-smoke.v2'
    started_at_utc = $startedAt.ToString('O')
    observation_seconds = $ObserveSeconds
    process_id = $null
    alive_at_deadline = $false
    main_window_created = $false
    desktop_checks = [bool]$DesktopChecks
    preview_mode = $PreviewMode
    screenshots = @()
    navigation_checks = @()
    embedded_chat_absent = $false
    support_website_available = $false
    settings_preferences_available_during_refresh = $false
    settings_refresh_cancelled_on_navigation = $false
    single_instance_redirected = $false
    close_to_tray = $false
    second_launch_restored_window = $false
    maximized_window_preserved_on_reopen = $false
    minimized_window_restored_by_protocol = $false
    tray_auth_recovery_without_connect = $false
    tray_auth_recovery_diagnostic = $null
    preview_protocol_registration = $null
    preview_protocol_diagnostic = $null
    protocol_activation_restored_window = $false
    preview_protocol_unregistered = $null
    clean_exit = $false
    clean_exit_code = $null
    service_absent_after_checks = $null
    saved_session_absent_after_checks = $null
    stage = 'startup'
    exit_code = $null
    failure_type = $null
    crash_events = @()
}

function Wait-SmokeCondition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [ValidateRange(1, 15)][int]$TimeoutSeconds = 8,
        [Parameter(Mandatory = $true)][string]$Failure
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}

function Assert-PrimaryInstance {
    $process.Refresh()
    if ($process.HasExited) { throw 'Primary preview exited during desktop checks.' }
    $instances = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
    if ($instances.Count -ne 1 -or $instances[0].Id -ne $process.Id) {
        throw 'Preview activation did not preserve one original application instance.'
    }
}

function Invoke-RedirectedLaunch {
    param([Parameter(Mandatory = $true)][string]$Arguments)
    $secondary = Start-Process -FilePath $ApplicationPath -ArgumentList $Arguments `
        -WorkingDirectory (Split-Path -Parent $ApplicationPath) -PassThru
    $ownedProcesses.Add($secondary)
    if (-not $secondary.WaitForExit(10000)) {
        throw 'Secondary preview process did not complete bounded activation redirection.'
    }
    if ($secondary.ExitCode -ne 0) { throw 'Secondary preview activation exited unsuccessfully.' }
    Assert-PrimaryInstance
}

function Assert-SmokeTrayRecoveryDiagnostic {
    param(
        [Parameter(Mandatory = $true)]$Diagnostic,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][string]$Access,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    if ($Diagnostic.schema -cne 'vex.windows.ui-preview-tray-recovery.v1' -or
        $Diagnostic.process_id -ne $ProcessId -or $Diagnostic.preview_mode -cne $Mode -or
        $Diagnostic.scenario -cne $Scenario -or $Diagnostic.access -cne $Access -or
        $Diagnostic.handler_completed -isnot [bool] -or -not $Diagnostic.handler_completed -or
        $Diagnostic.connect_requests -ne 0 -or $Diagnostic.trusted_connect_requests -ne 0 -or
        $Diagnostic.connection_desired -isnot [bool] -or $Diagnostic.connection_desired -or
        $Diagnostic.waiting_for_browser_auth -isnot [bool] -or $Diagnostic.waiting_for_browser_auth) {
        throw 'Actual tray recovery changed connection intent, sent a connect request, opened browser auth or used the wrong preview state.'
    }
}

function Wait-SmokeTrayRecoveryDiagnostic {
    param([string]$Scenario, [string]$Access)
    $script:trayRecoveryDiagnostic = $null
    Wait-SmokeCondition -Failure 'Actual tray recovery did not complete with an isolated diagnostic.' -Condition {
        if (-not (Test-Path -LiteralPath $trayDiagnosticPath -PathType Leaf)) { return $false }
        $file = Get-Item -LiteralPath $trayDiagnosticPath
        if ($file.Length -le 0 -or $file.Length -gt 65536 -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Tray recovery diagnostic is not a bounded regular file.'
        }
        $diagnostic = Get-Content -LiteralPath $trayDiagnosticPath -Raw | ConvertFrom-Json
        if ($diagnostic.scenario -cne $Scenario) { return $false }
        Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $diagnostic -Scenario $Scenario -Access $Access `
            -Mode $PreviewMode -ProcessId $process.Id
        $script:trayRecoveryDiagnostic = $diagnostic
        $script:trayDiagnosticHash = (Get-FileHash -LiteralPath $trayDiagnosticPath -Algorithm SHA256).Hash
        return $true
    }
    return $script:trayRecoveryDiagnostic
}

function Assert-PreviewProtocolRegistration {
    if ($null -ne $protocolDiagnosticPath -and (Test-Path -LiteralPath $protocolDiagnosticPath -PathType Leaf)) {
        $diagnosticFile = Get-Item -LiteralPath $protocolDiagnosticPath
        if ($diagnosticFile.Length -gt 4096 -or
            ($diagnosticFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Preview protocol diagnostic file is not a bounded regular file.'
        }
        $diagnostic = Get-Content -LiteralPath $protocolDiagnosticPath -Raw | ConvertFrom-Json
        if ($diagnostic.schema -cne 'vex.windows.ui-preview-protocol-diagnostic.v1' -or
            $diagnostic.process_id -ne $process.Id -or $diagnostic.scheme -cne 'vexguard-ui-preview' -or
            $diagnostic.stage -notin @('executable-path', 'current-user-classes', 'existing-registration',
                'create-registration', 'write-registration', 'notify-shell', 'registered') -or
            $diagnostic.registered -isnot [bool] -or
            ($null -ne $diagnostic.failure_type -and $diagnostic.failure_type -notmatch '^[A-Za-z0-9_]{1,80}Exception$') -or
            ($null -ne $diagnostic.native_error_code -and $diagnostic.native_error_code -isnot [long] -and
                $diagnostic.native_error_code -isnot [int])) {
            throw 'Preview protocol diagnostic schema or ownership is invalid.'
        }
        $script:protocolDiagnosticHash = (Get-FileHash -LiteralPath $protocolDiagnosticPath -Algorithm SHA256).Hash
        $result.preview_protocol_diagnostic = [ordered]@{
            stage = $diagnostic.stage
            registered = $diagnostic.registered
            failure_type = $diagnostic.failure_type
            native_error_code = $diagnostic.native_error_code
        }
        Write-Host "Preview protocol diagnostic: stage=$($diagnostic.stage); registered=$($diagnostic.registered); type=$($diagnostic.failure_type); native-code=$($diagnostic.native_error_code)."
    }
    $registration = [ordered]@{
        present = Test-Path -LiteralPath $previewProtocolKey
        owner_matches = $false
        structure_matches = $false
        command_matches = $false
    }
    $result.preview_protocol_registration = $registration
    if (-not $registration.present) {
        throw 'Temporary preview protocol registration is missing.'
    }
    $key = Get-Item -LiteralPath $previewProtocolKey
    $shell = $null
    $open = $null
    $command = $null
    try {
        $shell = $key.OpenSubKey('shell')
        if ($null -ne $shell) { $open = $shell.OpenSubKey('open') }
        if ($null -ne $open) { $command = $open.OpenSubKey('command') }
        $owner = $key.GetValue('VexUiPreviewOwner', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $registration.owner_matches = $owner -is [string] -and
            $key.GetValueKind('VexUiPreviewOwner') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            [string]::Equals($owner, $ApplicationPath, [StringComparison]::OrdinalIgnoreCase)
        $registration.structure_matches = $key.ValueCount -eq 4 -and $key.SubKeyCount -eq 1 -and
            $key.GetValueKind('VexUiPreviewSchema') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            $key.GetValue('VexUiPreviewSchema') -ceq 'vex.windows.ui-preview-protocol.v1' -and
            $key.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            $key.GetValue('') -ceq 'URL:VEX isolated UI preview' -and
            $key.GetValueKind('URL Protocol') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            $key.GetValue('URL Protocol') -ceq '' -and
            $null -ne $shell -and $shell.ValueCount -eq 0 -and $shell.SubKeyCount -eq 1 -and
            $null -ne $open -and $open.ValueCount -eq 0 -and $open.SubKeyCount -eq 1 -and
            $null -ne $command -and $command.ValueCount -eq 1 -and $command.SubKeyCount -eq 0
        if ($registration.owner_matches -and $null -ne $command) {
            $registration.command_matches =
                $command.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                $command.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq
                    ('"' + $owner + '" "%1"')
        }
        Write-Host "Preview protocol registration: present=$($registration.present); owner=$($registration.owner_matches); structure=$($registration.structure_matches); command=$($registration.command_matches)."
        if (-not $registration.owner_matches -or -not $registration.structure_matches -or
            -not $registration.command_matches) {
            throw 'Temporary preview protocol registration does not match its isolated owner.'
        }
    }
    finally {
        if ($null -ne $command) { $command.Dispose() }
        if ($null -ne $open) { $open.Dispose() }
        if ($null -ne $shell) { $shell.Dispose() }
        $key.Dispose()
    }
}

function Find-SmokeElement {
    param([Parameter(Mandatory = $true)][string]$AutomationId)
    $root = [Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    if ($null -eq $root) { return $null }
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    return $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-SmokeElement {
    param([Parameter(Mandatory = $true)][string]$AutomationId)
    $element = $null
    Wait-SmokeCondition -Failure "Visible UI element is missing: $AutomationId" -Condition {
        $script:smokeElement = Find-SmokeElement -AutomationId $AutomationId
        $null -ne $script:smokeElement -and -not $script:smokeElement.Current.IsOffscreen
    }
    $element = $script:smokeElement
    if (-not $element.Current.IsEnabled) { throw "UI element is disabled: $AutomationId" }
    $pattern = $null
    if ($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([Windows.Automation.InvokePattern]$pattern).Invoke()
    }
    elseif ($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        ([Windows.Automation.SelectionItemPattern]$pattern).Select()
    }
    elseif ($element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
        ([Windows.Automation.TogglePattern]$pattern).Toggle()
    }
    else { throw "UI element has no supported interaction pattern: $AutomationId" }
}

function Set-SmokeWindowBounds {
    param([int]$Left, [int]$Top, [int]$Width, [int]$Height)
    # SWP_ASYNCWINDOWPOS | SWP_NOZORDER | SWP_NOACTIVATE; wait separately with a deadline.
    if (-not [Vex.Windows.Smoke.NativeMethods]::SetWindowPos(
        $windowHandle, [System.IntPtr]::Zero, $Left, $Top, $Width, $Height, 0x4014)) {
        throw 'Unable to resize the preview window.'
    }
    Wait-SmokeCondition -Failure 'Preview window did not reach its requested bounds.' -Condition {
        $bounds = [Vex.Windows.Smoke.WindowRect]::new()
        [Vex.Windows.Smoke.NativeMethods]::GetWindowRect($windowHandle, [ref]$bounds) -and
        $bounds.Left -eq $Left -and $bounds.Top -eq $Top -and
        ($bounds.Right - $bounds.Left) -eq $Width -and
        ($bounds.Bottom - $bounds.Top) -eq $Height
    }
}

function Wait-SmokeCaptureBounds {
    param(
        [Parameter(Mandatory = $true)][string[]]$AutomationIds,
        [Parameter(Mandatory = $true)]$WindowBounds
    )
    $started = [DateTime]::UtcNow
    $state = @{ signature = ''; stable_since = $started; elements = @() }
    Wait-SmokeCondition -Failure 'Preview controls did not settle fully inside the visible window.' -Condition {
        $elements = @()
        foreach ($id in $AutomationIds) {
            $element = Find-SmokeElement -AutomationId $id
            if ($null -eq $element -or $element.Current.IsOffscreen) {
                $state.stable_since = [DateTime]::UtcNow
                return $false
            }
            $rect = $element.Current.BoundingRectangle
            if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0 -or
                $rect.Left -lt $WindowBounds.Left -or $rect.Top -lt $WindowBounds.Top -or
                $rect.Right -gt $WindowBounds.Right -or $rect.Bottom -gt $WindowBounds.Bottom) {
                $state.stable_since = [DateTime]::UtcNow
                return $false
            }
            $elements += [ordered]@{
                automation_id = $id
                left = [Math]::Round($rect.Left, 1)
                top = [Math]::Round($rect.Top, 1)
                width = [Math]::Round($rect.Width, 1)
                height = [Math]::Round($rect.Height, 1)
            }
        }
        $signature = $elements | ConvertTo-Json -Compress
        if ($signature -cne $state.signature) {
            $state.signature = $signature
            $state.stable_since = [DateTime]::UtcNow
        }
        $state.elements = $elements
        # UIA bounds must settle; allow the compositor-only Frame entrance to
        # finish as well, without disabling the application's user animations.
        ([DateTime]::UtcNow - $started).TotalMilliseconds -ge 1500 -and
            ([DateTime]::UtcNow - $state.stable_since).TotalMilliseconds -ge 600
    }
    return $state.elements
}

function Get-SmokeCaptureCursorPoint {
    param($Desktop, $WindowBounds)
    foreach ($point in @(
        [pscustomobject]@{ X = $Desktop.Left + 2; Y = $Desktop.Top + 2 },
        [pscustomobject]@{ X = $Desktop.Right - 3; Y = $Desktop.Top + 2 },
        [pscustomobject]@{ X = $Desktop.Left + 2; Y = $Desktop.Bottom - 3 },
        [pscustomobject]@{ X = $Desktop.Right - 3; Y = $Desktop.Bottom - 3 }
    )) {
        if ($point.X -lt $WindowBounds.Left -or $point.X -ge $WindowBounds.Right -or
            $point.Y -lt $WindowBounds.Top -or $point.Y -ge $WindowBounds.Bottom) {
            return $point
        }
    }
    throw 'No visible desktop point exists outside the preview window.'
}

function Set-SmokeCaptureFocus {
    param([Parameter(Mandatory = $true)][string[]]$AutomationIds)
    foreach ($automationId in $AutomationIds) {
        $element = Find-SmokeElement -AutomationId $automationId
        if ($null -ne $element -and -not $element.Current.IsOffscreen -and
            $element.Current.IsEnabled -and $element.Current.IsKeyboardFocusable) {
            $element.SetFocus()
            return $automationId
        }
    }
    throw 'No visible enabled page control can receive capture focus.'
}

function Save-SmokeScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$StableAutomationIds
    )
    Assert-PrimaryInstance
    [void][Vex.Windows.Smoke.NativeMethods]::SetForegroundWindow($windowHandle)
    Wait-SmokeCondition -Failure 'Preview window is not visible in the foreground.' -Condition {
        [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
        [Vex.Windows.Smoke.NativeMethods]::GetForegroundWindow() -eq $windowHandle
    }
    # Capture the actual displayed WinUI surface, including DirectComposition content.
    # PrintWindow can return an empty image for that surface on hosted Windows runners.
    $bounds = [Vex.Windows.Smoke.WindowRect]::new()
    $boundsAvailable = [Vex.Windows.Smoke.NativeMethods]::DwmGetWindowAttribute(
        $windowHandle, 9, [ref]$bounds, 16) -eq 0
    if (-not $boundsAvailable) {
        $boundsAvailable = [Vex.Windows.Smoke.NativeMethods]::GetWindowRect($windowHandle, [ref]$bounds)
    }
    if (-not $boundsAvailable) { throw 'Unable to measure the preview window.' }
    $width = $bounds.Right - $bounds.Left
    $height = $bounds.Bottom - $bounds.Top
    $desktop = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($width -lt 400 -or $height -lt 300 -or
        $bounds.Left -lt $desktop.Left -or $bounds.Top -lt $desktop.Top -or
        $bounds.Right -gt $desktop.Right -or $bounds.Bottom -gt $desktop.Bottom) {
        throw 'Preview window is too small or extends outside the visible desktop.'
    }
    # UIA navigation can leave the pointer over a dock button. Move it outside
    # the app so hover tooltips and states do not obscure the reference image.
    $cursorPoint = Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $bounds
    if (-not [Vex.Windows.Smoke.NativeMethods]::SetCursorPos($cursorPoint.X, $cursorPoint.Y)) {
        throw 'Unable to move the cursor outside the preview window.'
    }
    # UIA navigation also focuses the dock, which can retain a keyboard tooltip
    # after the pointer moves away. Focus a page control without activating it.
    $focusIds = if ($Name -eq 'account') { @('AccountCheckoutButton') }
        else { $StableAutomationIds }
    [void](Set-SmokeCaptureFocus -AutomationIds $focusIds)
    $pickerClose = Find-SmokeElement -AutomationId 'CloseServerPickerButton'
    if ($null -eq $pickerClose -or $pickerClose.Current.IsOffscreen) {
        # Escape dismisses a retained keyboard tooltip. Never send it while the
        # picker dialog is open, because that would dismiss the captured dialog.
        if ([Vex.Windows.Smoke.NativeMethods]::GetForegroundWindow() -ne $windowHandle) {
            throw 'Preview lost foreground focus before tooltip dismissal.'
        }
        [Windows.Forms.SendKeys]::SendWait('{ESC}')
    }
    $tooltipCondition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ToolTip),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
    Wait-SmokeCondition -TimeoutSeconds 15 -Failure 'Preview hover tooltip did not dismiss before capture.' -Condition {
        $tooltips = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Descendants, $tooltipCondition)
        foreach ($tooltip in $tooltips) {
            if (-not $tooltip.Current.IsOffscreen) { return $false }
        }
        return $true
    }
    $visibleElements = @(Wait-SmokeCaptureBounds -AutomationIds $StableAutomationIds -WindowBounds $bounds)
    $path = Join-Path $ScreenshotDirectory "$PreviewMode-$Name.png"
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($y = 0; $y -lt $height; $y += 11) {
            for ($x = 0; $x -lt $width; $x += 11) {
                [void]$colors.Add($bitmap.GetPixel($x, $y).ToArgb())
            }
        }
        if ($colors.Count -lt 8) { throw 'Preview screenshot is blank or has insufficient rendered content.' }
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        $result.screenshots += [ordered]@{
            name = $Name
            file = [IO.Path]::GetFileName($path)
            width = $width
            height = $height
            left = $bounds.Left
            top = $bounds.Top
            sampled_colors = $colors.Count
            visible_elements = $visibleElements
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Write-Host "WinUI screenshot captured: $PreviewMode-$Name.png ($width x $height)."
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Save-SmokeSupportWebsiteScreenshot {
    $viewport = Find-SmokeElement -AutomationId 'SettingsScrollViewer'
    if ($null -eq $viewport -or $viewport.Current.IsOffscreen) {
        throw 'Settings scroll viewport is unavailable.'
    }
    $pattern = $null
    if (-not $viewport.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$pattern)) {
        throw 'Settings viewport does not provide its scroll interaction pattern.'
    }
    $scroll = [Windows.Automation.ScrollPattern]$pattern
    $originalPercent = $scroll.Current.VerticalScrollPercent
    $state = @{ requested_percent = $originalPercent }
    try {
        Wait-SmokeCondition -TimeoutSeconds 15 -Failure 'Website support link is not fully visible in Settings.' -Condition {
            $button = Find-SmokeElement -AutomationId 'SettingsSupportWebsiteButton'
            if ($null -ne $button -and -not $button.Current.IsOffscreen) {
                $rect = $button.Current.BoundingRectangle
                $visible = $viewport.Current.BoundingRectangle
                if (-not $rect.IsEmpty -and $rect.Width -gt 0 -and $rect.Height -gt 0 -and
                    $rect.Left -ge $visible.Left -and $rect.Right -le $visible.Right -and
                    $rect.Top -ge $visible.Top -and $rect.Bottom -le $visible.Bottom) {
                    if (-not $button.Current.IsEnabled -or $button.Current.Name -cne 'Поддержка на сайте') {
                        throw 'Website support link is disabled or has an unexpected accessible name.'
                    }
                    return $true
                }
            }
            if (-not $scroll.Current.VerticallyScrollable) {
                throw 'Website support link is absent from the non-scrolling Settings viewport.'
            }
            $currentPercent = $scroll.Current.VerticalScrollPercent
            # Await the requested movement before advancing. Half a viewport
            # keeps successive ranges overlapping so a short link is not skipped.
            if ([Math]::Abs($currentPercent - $state.requested_percent) -le 0.2) {
                if ($currentPercent -ge 100) { throw 'Website support link was not found within Settings.' }
                $step = [Math]::Max(1, [Math]::Min(20, $scroll.Current.VerticalViewSize / 2))
                $state.requested_percent = [Math]::Min(100, $currentPercent + $step)
                $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, $state.requested_percent)
            }
            return $false
        }
        Save-SmokeScreenshot -Name 'settings-support-link' -StableAutomationIds @('SettingsSupportWebsiteButton')
        $result.support_website_available = $true
        Write-Host "WinUI website support checked: $PreviewMode; visible=True; enabled=True; expected-name=True."
    }
    finally {
        if ($originalPercent -ge 0 -and $scroll.Current.VerticallyScrollable) {
            $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, $originalPercent)
            Wait-SmokeCondition -Failure 'Settings scroll position was not restored after support link capture.' -Condition {
                [Math]::Abs($scroll.Current.VerticalScrollPercent - $originalPercent) -le 0.2
            }
        }
    }
}

try {
    $launch = @{
        FilePath = $ApplicationPath
        WorkingDirectory = Split-Path -Parent $ApplicationPath
        PassThru = $true
    }
    if ($DesktopChecks) { $launch.ArgumentList = $previewArguments }
    $process = Start-Process @launch
    $ownedProcesses.Add($process)
    $result.process_id = $process.Id
    if ($DesktopChecks) {
        $protocolDiagnosticPath = Join-Path ([IO.Path]::GetTempPath()) "vex-ui-preview-protocol-$($process.Id).json"
        $trayDiagnosticPath = Join-Path ([IO.Path]::GetTempPath()) "vex-ui-preview-tray-$($process.Id).json"
    }
    $deadline = $startedAt.AddSeconds($ObserveSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            $result.exit_code = $process.ExitCode
            throw 'Published WinUI application exited during startup.'
        }
        if ($process.MainWindowHandle -ne 0) {
            $result.main_window_created = $true
        }
        Start-Sleep -Milliseconds 250
    }
    $process.Refresh()
    if ($process.HasExited) {
        $result.exit_code = $process.ExitCode
        throw 'Published WinUI application exited before the observation deadline.'
    }
    $result.alive_at_deadline = $true
    Write-Host "WinUI application remained alive for $ObserveSeconds seconds."
    Write-Host "WinUI main window created: $($result.main_window_created)."
    if ($DesktopChecks) {
        if (-not $result.main_window_created) { throw 'Desktop preview did not create a main window.' }
        $windowHandle = $process.MainWindowHandle
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        if (-not ('Vex.Windows.Smoke.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Vex.Windows.Smoke {
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowPoint { public int X, Y; }
    public static class NativeMethods {
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out WindowPoint point);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out WindowRect rect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", EntryPoint = "PostMessageW")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out WindowRect value, int size);
    }
}
'@
        }
        $previousDpiContext = [Vex.Windows.Smoke.NativeMethods]::SetThreadDpiAwarenessContext([System.IntPtr](-4))
        $originalCursorPosition = [Vex.Windows.Smoke.WindowPoint]::new()
        if (-not [Vex.Windows.Smoke.NativeMethods]::GetCursorPos([ref]$originalCursorPosition)) {
            throw 'Unable to preserve the desktop cursor position.'
        }
        if ([string]::IsNullOrEmpty($ScreenshotDirectory)) {
            $ScreenshotDirectory = Join-Path (Split-Path -Parent $ResultPath) 'screenshots'
        }
        New-Item -ItemType Directory -Path $ScreenshotDirectory -Force | Out-Null
        $result.stage = 'initial-screenshot'
        $captureControlIds = if ($PreviewMode -eq 'signed-out') {
            @('AccountSignInTitle', 'WebsiteSignInButton')
        }
        else { @('PowerButton', 'ServerPickerButton') }
        Save-SmokeScreenshot -Name 'initial' -StableAutomationIds $captureControlIds
        $pages = if ($PreviewMode -eq 'signed-out') { @('Home', 'Settings') }
            else { @('Home', 'Account', 'Settings') }
        foreach ($removedControlId in @('SupportNavigationButton', 'SupportMessageInput', 'SendSupportMessageButton')) {
            if ($null -ne (Find-SmokeElement -AutomationId $removedControlId)) {
                throw 'The desktop still exposes embedded support chat.'
            }
        }
        $result.embedded_chat_absent = $true
        if ($PreviewMode -eq 'signed-out') {
            foreach ($hiddenNavigationId in @('AccountNavigationButton')) {
                $element = Find-SmokeElement -AutomationId $hiddenNavigationId
                if ($null -ne $element -and -not $element.Current.IsOffscreen) {
                    throw 'Signed-out preview exposes account navigation.'
                }
            }
        }
        foreach ($page in $pages) {
            $result.stage = "navigation-$($page.ToLowerInvariant())"
            Invoke-SmokeElement -AutomationId "${page}NavigationButton"
            # WinUI Page is a layout container without a PageAutomationPeer.
            # Require a visible interactive control unique to the loaded page.
            $expectedControlId = if ($PreviewMode -eq 'signed-out' -and $page -eq 'Home') {
                'WebsiteSignInButton'
            }
            else {
                switch ($page) {
                    'Home' { 'PowerButton' }
                    'Account' { 'RefreshBillingButton' }
                    'Settings' { 'AutoLaunchToggle' }
                }
            }
            Wait-SmokeCondition -Failure "Preview page did not load: $page" -Condition {
                $element = Find-SmokeElement -AutomationId $expectedControlId
                $null -ne $element -and -not $element.Current.IsOffscreen
            }
            $result.navigation_checks += [ordered]@{
                section = $page
                visible_control = $expectedControlId
            }
            if ($page -eq 'Settings') {
                # The Debug fixture holds the remote-config read for five
                # seconds. Exercise a local preference without OS registration.
                Wait-SmokeCondition -TimeoutSeconds 3 -Failure 'Settings blocked local preferences during its slow read-only refresh.' -Condition {
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $recoveryToggle = Find-SmokeElement -AutomationId 'AutoRecoveryToggle'
                    $null -ne $refreshButton -and -not $refreshButton.Current.IsEnabled -and
                        $null -ne $recoveryToggle -and $recoveryToggle.Current.IsEnabled
                }
                $recoveryToggle = Find-SmokeElement -AutomationId 'AutoRecoveryToggle'
                $recoveryPattern = [Windows.Automation.TogglePattern]$recoveryToggle.GetCurrentPattern(
                    [Windows.Automation.TogglePattern]::Pattern)
                $originalRecoveryState = $recoveryPattern.Current.ToggleState
                if ($originalRecoveryState -eq [Windows.Automation.ToggleState]::Indeterminate) {
                    throw 'AutoRecovery must expose a two-state preference.'
                }
                $resumedRefreshTimer = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $recoveryPattern.Toggle()
                    Wait-SmokeCondition -TimeoutSeconds 3 -Failure 'AutoRecovery did not change while its read-only refresh resumed.' -Condition {
                        $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                        $recoveryToggle = Find-SmokeElement -AutomationId 'AutoRecoveryToggle'
                        if ($null -eq $refreshButton -or $null -eq $recoveryToggle -or
                            -not $recoveryToggle.Current.IsEnabled) { return $false }
                        $pattern = [Windows.Automation.TogglePattern]$recoveryToggle.GetCurrentPattern(
                            [Windows.Automation.TogglePattern]::Pattern)
                        $pattern.Current.ToggleState -ne $originalRecoveryState -and
                            -not $refreshButton.Current.IsEnabled
                    }
                }
                finally {
                    $recoveryToggle = Find-SmokeElement -AutomationId 'AutoRecoveryToggle'
                    if ($null -ne $recoveryToggle) {
                        $recoveryPattern = [Windows.Automation.TogglePattern]$recoveryToggle.GetCurrentPattern(
                            [Windows.Automation.TogglePattern]::Pattern)
                        if ($recoveryPattern.Current.ToggleState -ne $originalRecoveryState) {
                            $resumedRefreshTimer.Restart()
                            $recoveryPattern.Toggle()
                        }
                    }
                }
                Wait-SmokeCondition -TimeoutSeconds 3 -Failure 'AutoRecovery was not restored during the delayed refresh.' -Condition {
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $recoveryToggle = Find-SmokeElement -AutomationId 'AutoRecoveryToggle'
                    if ($null -eq $refreshButton -or $null -eq $recoveryToggle -or
                        -not $recoveryToggle.Current.IsEnabled) { return $false }
                    $pattern = [Windows.Automation.TogglePattern]$recoveryToggle.GetCurrentPattern(
                        [Windows.Automation.TogglePattern]::Pattern)
                    $pattern.Current.ToggleState -eq $originalRecoveryState -and
                        -not $refreshButton.Current.IsEnabled
                }
                Wait-SmokeCondition -Failure 'Settings did not finish its resumed read-only refresh.' -Condition {
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $null -ne $refreshButton -and $refreshButton.Current.IsEnabled
                }
                if ($resumedRefreshTimer.Elapsed.TotalSeconds -lt 4) {
                    throw 'Settings abandoned its delayed read instead of resuming after the preference change.'
                }
                $result.settings_preferences_available_during_refresh = $true

                # This status button is below the initial Settings viewport.
                # Invoke its enabled automation peer without scrolling; retain
                # the visibility requirement for all ordinary smoke actions.
                $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                $refreshPattern = $null
                if ($null -eq $refreshButton -or -not $refreshButton.Current.IsEnabled -or
                    -not $refreshButton.TryGetCurrentPattern(
                        [Windows.Automation.InvokePattern]::Pattern, [ref]$refreshPattern)) {
                    throw 'Settings refresh does not expose an enabled invoke pattern.'
                }
                ([Windows.Automation.InvokePattern]$refreshPattern).Invoke()
                Wait-SmokeCondition -TimeoutSeconds 3 -Failure 'Settings did not start the navigation-cancellation refresh.' -Condition {
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $null -ne $refreshButton -and -not $refreshButton.Current.IsEnabled
                }
                Invoke-SmokeElement -AutomationId 'HomeNavigationButton'
                $homeControlId = if ($PreviewMode -eq 'signed-out') { 'WebsiteSignInButton' } else { 'PowerButton' }
                Wait-SmokeCondition -Failure 'Home did not load while Settings was refreshing.' -Condition {
                    $element = Find-SmokeElement -AutomationId $homeControlId
                    $null -ne $element -and -not $element.Current.IsOffscreen
                }
                Assert-PrimaryInstance
                $navigationRefreshTimer = [Diagnostics.Stopwatch]::StartNew()
                Invoke-SmokeElement -AutomationId 'SettingsNavigationButton'
                Wait-SmokeCondition -Failure 'Settings did not reload after canceling its previous refresh.' -Condition {
                    $element = Find-SmokeElement -AutomationId 'AutoLaunchToggle'
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $null -ne $element -and -not $element.Current.IsOffscreen -and
                        $null -ne $refreshButton -and -not $refreshButton.Current.IsEnabled
                }
                Wait-SmokeCondition -Failure 'Settings did not finish refreshing after navigation cancellation.' -Condition {
                    $refreshButton = Find-SmokeElement -AutomationId 'RefreshSettingsButton'
                    $null -ne $refreshButton -and $refreshButton.Current.IsEnabled
                }
                if ($navigationRefreshTimer.Elapsed.TotalSeconds -lt 4) {
                    throw 'Settings did not perform a fresh delayed read after navigation cancellation.'
                }
                Assert-PrimaryInstance
                $result.settings_refresh_cancelled_on_navigation = $true
            }
            $captureControlIds = if ($PreviewMode -eq 'signed-out' -and $page -eq 'Home') {
                @('AccountSignInTitle', 'WebsiteSignInButton')
            }
            else {
                switch ($page) {
                    'Home' { @('PowerButton', 'ServerPickerButton') }
                    'Account' { @('AccountPageTitle', 'RefreshBillingButton') }
                    'Settings' { @('SettingsPageTitle', 'AutoLaunchToggle') }
                }
            }
            Save-SmokeScreenshot -Name $page.ToLowerInvariant() -StableAutomationIds $captureControlIds
            if ($page -eq 'Settings') {
                $result.stage = 'settings-support-link'
                Save-SmokeSupportWebsiteScreenshot
            }
            if ($page -eq 'Home' -and $PreviewMode -eq 'fixtures') {
                $result.stage = 'home-compact'
                $normalBounds = [Vex.Windows.Smoke.WindowRect]::new()
                if (-not [Vex.Windows.Smoke.NativeMethods]::GetWindowRect($windowHandle, [ref]$normalBounds)) {
                    throw 'Unable to save the original preview window bounds.'
                }
                try {
                    Set-SmokeWindowBounds -Left $normalBounds.Left -Top $normalBounds.Top -Width 640 -Height 540
                    Save-SmokeScreenshot -Name 'home-compact' -StableAutomationIds $captureControlIds
                }
                finally {
                    Set-SmokeWindowBounds -Left $normalBounds.Left -Top $normalBounds.Top `
                        -Width ($normalBounds.Right - $normalBounds.Left) `
                        -Height ($normalBounds.Bottom - $normalBounds.Top)
                }
                $result.stage = 'server-picker'
                Invoke-SmokeElement -AutomationId 'ServerPickerButton'
                Wait-SmokeCondition -Failure 'Server picker did not open.' -Condition {
                    $element = Find-SmokeElement -AutomationId 'CloseServerPickerButton'
                    $null -ne $element -and -not $element.Current.IsOffscreen
                }
                Save-SmokeScreenshot -Name 'server-picker' -StableAutomationIds @('CloseServerPickerButton')
                Invoke-SmokeElement -AutomationId 'CloseServerPickerButton'
                Wait-SmokeCondition -Failure 'Server picker did not close.' -Condition {
                    $element = Find-SmokeElement -AutomationId 'CloseServerPickerButton'
                    $null -eq $element -or $element.Current.IsOffscreen
                }
            }
        }
        $result.stage = 'tray-auth-recovery'
        if (-not [Vex.Windows.Smoke.NativeMethods]::PostMessage($windowHandle, 0x10, [System.IntPtr]::Zero, [System.IntPtr]::Zero)) {
            throw 'Unable to hide the preview before actual tray recovery.'
        }
        Wait-SmokeCondition -Failure 'Preview did not hide before actual tray recovery.' -Condition {
            -not [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle)
        }
        $trayScenario = if ($PreviewMode -eq 'fixtures') { 'locked' } else { 'signed-out' }
        $trayAccess = if ($PreviewMode -eq 'fixtures') { 'Locked' } else { 'Missing' }
        $trayArguments = if ($PreviewMode -eq 'fixtures') { '--ui-smoke-tray-connect-locked' } else { '--ui-smoke-tray-connect' }
        Invoke-RedirectedLaunch -Arguments $trayArguments
        $result.tray_auth_recovery_diagnostic = Wait-SmokeTrayRecoveryDiagnostic -Scenario $trayScenario -Access $trayAccess
        Wait-SmokeCondition -Failure 'Actual tray recovery did not show the Home sign-in or Hello unlock controls.' -Condition {
            $home = Find-SmokeElement -AutomationId 'HomeNavigationButton'
            $signIn = Find-SmokeElement -AutomationId 'WebsiteSignInButton'
            $unlock = Find-SmokeElement -AutomationId 'UnlockSessionButton'
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle) -and
                $null -ne $home -and $null -ne $signIn -and -not $signIn.Current.IsOffscreen -and $signIn.Current.IsEnabled -and
                ($PreviewMode -ne 'fixtures' -or ($null -ne $unlock -and -not $unlock.Current.IsOffscreen -and $unlock.Current.IsEnabled))
        }
        Assert-PrimaryInstance
        $result.tray_auth_recovery_without_connect = $true
        if ($PreviewMode -eq 'fixtures') {
            $result.stage = 'tray-auth-recovery-reset'
            Invoke-RedirectedLaunch -Arguments '--ui-smoke-tray-reset'
            Wait-SmokeTrayRecoveryDiagnostic -Scenario 'reset' -Access 'Available' | Out-Null
            Wait-SmokeCondition -Failure 'Locked tray fixture did not restore the authenticated Home after recovery checks.' -Condition {
                $power = Find-SmokeElement -AutomationId 'PowerButton'
                $null -ne $power -and -not $power.Current.IsOffscreen -and $power.Current.IsEnabled
            }
            Assert-PrimaryInstance
        }
        $result.stage = 'single-instance'
        Invoke-RedirectedLaunch -Arguments $previewArguments
        $result.single_instance_redirected = $true
        $activationBounds = [Vex.Windows.Smoke.WindowRect]::new()
        if (-not [Vex.Windows.Smoke.NativeMethods]::GetWindowRect($windowHandle, [ref]$activationBounds)) {
            throw 'Unable to preserve normal window placement before activation checks.'
        }
        $result.stage = 'maximize-window'
        [void][Vex.Windows.Smoke.NativeMethods]::ShowWindow($windowHandle, 3)
        Wait-SmokeCondition -Failure 'Preview did not maximize before close-to-tray.' -Condition {
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
                [Vex.Windows.Smoke.NativeMethods]::IsZoomed($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle)
        }
        $result.stage = 'close-to-tray'
        if (-not [Vex.Windows.Smoke.NativeMethods]::PostMessage($windowHandle, 0x10, [System.IntPtr]::Zero, [System.IntPtr]::Zero)) {
            throw 'Unable to request normal window close.'
        }
        Wait-SmokeCondition -Failure 'Window close did not hide the preview to its tray.' -Condition {
            -not [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle)
        }
        Assert-PrimaryInstance
        $result.close_to_tray = $true
        $result.stage = 'second-launch-restore'
        Invoke-RedirectedLaunch -Arguments $previewArguments
        Wait-SmokeCondition -Failure 'Second launch did not preserve the hidden preview maximization.' -Condition {
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
                [Vex.Windows.Smoke.NativeMethods]::IsZoomed($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle)
        }
        $result.second_launch_restored_window = $true
        $result.maximized_window_preserved_on_reopen = $true
        $result.stage = 'protocol-registration'
        Assert-PreviewProtocolRegistration
        $result.stage = 'minimized-protocol-activation'
        [void][Vex.Windows.Smoke.NativeMethods]::ShowWindow($windowHandle, 6)
        Wait-SmokeCondition -Failure 'Preview did not minimize before protocol activation.' -Condition {
            [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle)
        }
        Start-Process -FilePath 'vexguard-ui-preview://ui-smoke/activate'
        Wait-SmokeCondition -Failure 'Protocol activation did not restore the minimized preview to its maximized placement.' -Condition {
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle) -and
                [Vex.Windows.Smoke.NativeMethods]::IsZoomed($windowHandle)
        }
        Wait-SmokeCondition -Failure 'Minimized protocol activation left an additional application instance.' -Condition {
            @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue).Count -eq 1
        }
        Assert-PrimaryInstance
        $result.minimized_window_restored_by_protocol = $true
        $result.stage = 'restore-normal-window'
        [void][Vex.Windows.Smoke.NativeMethods]::ShowWindow($windowHandle, 9)
        Wait-SmokeCondition -Failure 'Preview did not recover its normal window placement before capture.' -Condition {
            $restoredBounds = [Vex.Windows.Smoke.WindowRect]::new()
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsIconic($windowHandle) -and
                -not [Vex.Windows.Smoke.NativeMethods]::IsZoomed($windowHandle) -and
                [Vex.Windows.Smoke.NativeMethods]::GetWindowRect($windowHandle, [ref]$restoredBounds) -and
                $restoredBounds.Left -eq $activationBounds.Left -and $restoredBounds.Top -eq $activationBounds.Top -and
                $restoredBounds.Right -eq $activationBounds.Right -and $restoredBounds.Bottom -eq $activationBounds.Bottom
        }
        $result.stage = 'protocol-activation'
        [void][Vex.Windows.Smoke.NativeMethods]::PostMessage($windowHandle, 0x10, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
        Wait-SmokeCondition -Failure 'Preview could not be hidden before protocol activation.' -Condition {
            -not [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle)
        }
        Start-Process -FilePath 'vexguard-ui-preview://ui-smoke/activate'
        Wait-SmokeCondition -Failure 'Registered protocol activation did not restore the preview.' -Condition {
            [Vex.Windows.Smoke.NativeMethods]::IsWindowVisible($windowHandle)
        }
        Wait-SmokeCondition -Failure 'Protocol activation left an additional application instance.' -Condition {
            @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue).Count -eq 1
        }
        Assert-PrimaryInstance
        $result.protocol_activation_restored_window = $true
        Save-SmokeScreenshot -Name 'protocol-restored' -StableAutomationIds $captureControlIds
        $result.stage = 'clean-exit'
        $exitRequest = Start-Process -FilePath $ApplicationPath -ArgumentList '--ui-smoke-exit' `
            -WorkingDirectory (Split-Path -Parent $ApplicationPath) -PassThru
        $ownedProcesses.Add($exitRequest)
        if (-not $exitRequest.WaitForExit(10000) -or $exitRequest.ExitCode -ne 0) {
            throw 'Preview clean-exit activation failed.'
        }
        if (-not $process.WaitForExit(10000)) { throw 'Preview did not exit cleanly within the deadline.' }
        $result.clean_exit_code = $process.ExitCode
        $result.exit_code = $process.ExitCode
        if ($process.ExitCode -ne 0) { throw 'Preview clean close returned a failure exit code.' }
        $result.clean_exit = $true
        $result.preview_protocol_unregistered = -not (Test-Path -LiteralPath $previewProtocolKey)
        $result.service_absent_after_checks = -not [bool](Get-Service -Name 'VEX VPN Service', 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue)
        $result.saved_session_absent_after_checks = -not (Test-Path -LiteralPath $sessionPath)
        if (-not $result.preview_protocol_unregistered) {
            throw 'Preview clean exit left its temporary shell protocol registered.'
        }
        if (-not $result.service_absent_after_checks -or -not $result.saved_session_absent_after_checks) {
            throw 'UI preview created VPN service or production session state.'
        }
        Write-Host "WinUI desktop checks passed: $PreviewMode; screenshots=$($result.screenshots.Count); single-instance=True; protocol-restored=True; clean-exit=True."
    }
    $result.stage = 'completed'
}
catch {
    $result.failure_type = $_.Exception.GetType().FullName
    throw
}
finally {
    foreach ($owned in $ownedProcesses) {
        $owned.Refresh()
        if (-not $owned.HasExited) {
            Stop-Process -Id $owned.Id -Force -ErrorAction SilentlyContinue
            [void]$owned.WaitForExit(5000)
        }
    }
    if ($null -ne $originalCursorPosition) {
        [void][Vex.Windows.Smoke.NativeMethods]::SetCursorPos($originalCursorPosition.X, $originalCursorPosition.Y)
    }
    if ($null -ne $protocolDiagnosticHash -and (Test-Path -LiteralPath $protocolDiagnosticPath -PathType Leaf)) {
        $diagnosticFile = Get-Item -LiteralPath $protocolDiagnosticPath
        if (($diagnosticFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            (Get-FileHash -LiteralPath $protocolDiagnosticPath -Algorithm SHA256).Hash -ceq $protocolDiagnosticHash) {
            Remove-Item -LiteralPath $protocolDiagnosticPath
        }
    }
    if ($null -ne $trayDiagnosticHash -and (Test-Path -LiteralPath $trayDiagnosticPath -PathType Leaf)) {
        $diagnosticFile = Get-Item -LiteralPath $trayDiagnosticPath
        if (($diagnosticFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            (Get-FileHash -LiteralPath $trayDiagnosticPath -Algorithm SHA256).Hash -ceq $trayDiagnosticHash) {
            Remove-Item -LiteralPath $trayDiagnosticPath
        }
    }
    if ($previousDpiContext -ne [System.IntPtr]::Zero) {
        [void][Vex.Windows.Smoke.NativeMethods]::SetThreadDpiAwarenessContext($previousDpiContext)
    }
    # Store only selected event identifiers and fault module/code fields.
    # Raw event messages, stdout, account state and process dumps are excluded.
    $result.crash_events = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            StartTime = $startedAt.ToLocalTime()
            Id = @(1000, 1001, 1026)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like '*Vex.Windows.App.exe*' } |
            Select-Object -First 5 |
            ForEach-Object {
                $event = $_
                [xml]$xml = $event.ToXml()
                $fields = [ordered]@{}
                foreach ($data in @($xml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]'))) {
                    if ($data.GetAttribute('Name') -in @('AppName', 'ModuleName', 'ExceptionCode')) {
                        $fields[$data.GetAttribute('Name')] = $data.InnerText
                    }
                }
                [ordered]@{
                    event_id = $event.Id
                    provider = $event.ProviderName
                    time_utc = $event.TimeCreated.ToUniversalTime().ToString('O')
                    fields = $fields
                }
            }
    )
    $directory = Split-Path -Parent $ResultPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
