# Shared test-harness transport; the normal Windows association chooses the app.
# https://learn.microsoft.com/en-us/windows/win32/shell/shell-shellexecute
function Invoke-AcceptanceProtocolCallback {
    param([Parameter(Mandatory = $true)][Uri]$Callback)
    if (-not $Callback.IsAbsoluteUri -or $Callback.Scheme -cne 'vexguard' -or
        $Callback.Host -cne 'auth' -or $Callback.AbsolutePath -cne '/callback' -or
        $Callback.UserInfo.Length -ne 0 -or $Callback.Port -ne -1 -or
        $Callback.Fragment.Length -ne 0 -or $Callback.Query.Length -eq 0) {
        throw 'The protocol callback left its fixed native origin.'
    }
    $shell = New-Object -ComObject Shell.Application
    try {
        # Acceptance of this Shell request is not proof of application delivery.
        $null = $shell.ShellExecute($Callback.AbsoluteUri, '', '', 'open', 1)
    }
    finally {
        if ([Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}
