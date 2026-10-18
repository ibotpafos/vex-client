# Pure validation only: no account, network, certificate-store or install action.
function Read-WindowsProductionBrowserRequest {
    param([string]$Value)
    if ($Value.Length -gt 8192) { return $null }
    # An elided address bar is not evidence of HTTPS. Its UIA reader must
    # reveal the full address before this pure parser can trust the origin.
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'vexguard.app' -or $uri.Port -ne 443 -or $uri.UserInfo.Length -ne 0) { return $null }
    if ($uri.AbsolutePath -ceq '/sign-in') {
        $login = [Web.HttpUtility]::ParseQueryString($uri.Query)
        $callback = $login.Get('callbackUrl')
        if ([string]::IsNullOrWhiteSpace($callback)) { return $null }
        if (@($login.GetValues('callbackUrl')).Count -ne 1) { throw [InvalidOperationException]::new('The native browser callback is ambiguous.') }
        if (-not $callback -or -not $callback.StartsWith('/auth/app?', [StringComparison]::Ordinal)) { return $null }
        $uri = [Uri]::new([Uri]'https://vexguard.app', $callback)
    }
    if ($uri.AbsolutePath -cne '/auth/app') { return $null }
    $query = [Web.HttpUtility]::ParseQueryString($uri.Query)
    foreach ($key in @('state', 'code_challenge', 'device_id', 'device_name', 'platform')) {
        if (@($query.GetValues($key)).Count -ne 1 -or [string]::IsNullOrWhiteSpace($query.Get($key))) { throw [InvalidOperationException]::new('The native browser request is ambiguous.') }
    }
    # Native PkceAuthFlow.CreateRandomString uses URI-unreserved -._~ for its
    # state. The SHA-256 challenge separately remains base64url, without .~.
    if ($query.Get('platform') -cne 'windows' -or $query.Get('state') -cnotmatch '^[A-Za-z0-9._~-]{16,128}$' -or
        $query.Get('code_challenge') -cnotmatch '^[A-Za-z0-9_-]{43}$') { throw [InvalidOperationException]::new('The native browser request is invalid.') }
    return ,$query
}

function Read-WindowsProductionQaPayload {
    param(
        [string]$Raw,
        [string]$ExpectedSha256,
        [string]$ReleaseSourceCommit,
        [long]$ReleaseRunId,
        [long]$NowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )
    if ([string]::IsNullOrEmpty($Raw) -or [Text.Encoding]::UTF8.GetByteCount($Raw) -gt 16384 -or
        $ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or $ReleaseSourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $ReleaseRunId -le 0) {
        throw 'A bounded, pinned limited tester identity is required.'
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Raw))).ToLowerInvariant()
    if ($hash -cne $ExpectedSha256) { throw 'The limited tester identity changed after its approved plan.' }
    try { $value = $Raw | ConvertFrom-Json } catch { throw 'The limited tester identity is invalid.' }
    $keys = @('schema', 'namespace', 'user_id', 'email', 'token', 'expires_at_unix', 'release_version', 'release_build',
        'expected_exit_ipv4', 'campaign_id', 'release_source_commit', 'release_run_id')
    if ($null -eq $value -or @($value.PSObject.Properties.Name).Count -ne $keys.Count -or
        @($value.PSObject.Properties.Name | Where-Object { $_ -cnotin $keys }).Count) { throw 'The limited tester payload has unexpected fields.' }
    if ($value.schema -cne 'vex.windows-tester-qa.v1' -or $value.namespace -cnotmatch '^[a-f0-9]{32}$' -or
        $value.user_id -cne ('usr_' + $value.namespace) -or $value.email -cne ('tester-acceptance-' + $value.namespace + '@example.test') -or
        $value.token -cnotmatch '^[a-f0-9]{64}$' -or $value.release_source_commit -cne $ReleaseSourceCommit -or
        $value.campaign_id -cnotmatch '^[A-Za-z0-9_-]{1,160}$') {
        throw 'Production QA accepts only this release and its unexpired ordinary synthetic tester.'
    }
    if (($value.release_run_id -isnot [long] -and $value.release_run_id -isnot [int]) -or $value.release_run_id -ne $ReleaseRunId -or
        ($value.release_build -isnot [long] -and $value.release_build -isnot [int]) -or $value.release_build -le 0 -or $value.release_build -gt 9007199254740991) {
        throw 'The tester identity is not bound to the exact release run and build.'
    }
    if (($value.expires_at_unix -isnot [double] -and $value.expires_at_unix -isnot [long] -and $value.expires_at_unix -isnot [int]) -or
        -not [double]::IsFinite([double]$value.expires_at_unix) -or $value.expires_at_unix -le $NowUnix -or $value.expires_at_unix -gt ($NowUnix + 7200)) {
        throw 'The limited tester identity must expire within two hours.'
    }
    if ($value.release_version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        @($value.release_version.Split('.') | Where-Object { [double]$_ -gt 65535 }).Count -or $value.release_version -ceq '0.0.0.0') {
        throw 'The exact Windows release version is invalid.'
    }
    if ($value.expected_exit_ipv4 -isnot [array] -or $value.expected_exit_ipv4.Count -lt 1 -or $value.expected_exit_ipv4.Count -gt 16) {
        throw 'A bounded set of production exits is required.'
    }
    # Use the public observer's existing address policy without executing it.
    $source = Join-Path $PSScriptRoot 'verify-public-vpn.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    $definitions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ConvertTo-PublicVpnIpv4' }, $false))
    if ($errors.Count -ne 0 -or $definitions.Count -ne 1) { throw 'The reviewed public observer address policy is unavailable.' }
    Invoke-Expression $definitions[0].Extent.Text
    foreach ($address in $value.expected_exit_ipv4) {
        if ($address -isnot [string]) { throw 'A production exit must be a public IPv4 address.' }
        $null = ConvertTo-PublicVpnIpv4 $address
    }
    if (@($value.expected_exit_ipv4 | Sort-Object -Unique).Count -ne $value.expected_exit_ipv4.Count) { throw 'Production exit pins must be distinct.' }
    return $value
}
