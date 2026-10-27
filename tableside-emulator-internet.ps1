[CmdletBinding()]
param(
    [ValidateSet('Block', 'Allow')]
    [string]$Mode = 'Block',

    [string]$LanSubnet = '192.168.254.0/24',

    [string]$HubAddress = '192.168.254.200',

    [string]$AdbPath = 'adb'
)

$ErrorActionPreference = 'Stop'
$ipv4Chain = 'TABLESIDE_OFFLINE'
$ipv6Chain = 'TABLESIDE_OFFLINE6'
$legacyWindowsRule = 'TableSide Emulator Block Internet'

function Invoke-Adb([string[]]$CommandArguments, [switch]$IgnoreFailure) {
    if ($IgnoreFailure) {
        & $AdbPath @CommandArguments 2>$null
    } else {
        & $AdbPath @CommandArguments
    }
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreFailure -and $exitCode -ne 0) {
        throw "adb command failed ($exitCode): $($CommandArguments -join ' ')"
    }
    return $exitCode
}

function Remove-OutputJump([string]$Tool, [string]$Chain) {
    # Remove every stale jump, including duplicates left by interrupted tests.
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        & $AdbPath shell $Tool -C OUTPUT -j $Chain 2>$null
        if ($LASTEXITCODE -ne 0) { break }
        & $AdbPath shell $Tool -D OUTPUT -j $Chain 2>$null
        if ($LASTEXITCODE -ne 0) { break }
    }
}

function Test-Address([string]$Address) {
    & $AdbPath shell ping -c 1 -W 3 $Address *> $null
    return $LASTEXITCODE -eq 0
}

# An earlier test used Windows' broad "Internet" address keyword. Remove it
# when this shell is elevated; otherwise explain the one-time cleanup command.
$legacyRule = Get-NetFirewallRule -DisplayName $legacyWindowsRule -ErrorAction SilentlyContinue
if ($legacyRule) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $legacyRule | Remove-NetFirewallRule
    } else {
        Write-Warning "Obsolete Windows rule '$legacyWindowsRule' still exists. Remove it once from Administrator PowerShell: Remove-NetFirewallRule -DisplayName '$legacyWindowsRule'"
    }
}

Invoke-Adb @('get-state') | Out-Null

# Always clean both chains first. Rebuilding from an empty chain fixes the old
# failure where duplicate OUTPUT jumps bypassed newly-added LAN exceptions.
Remove-OutputJump 'iptables' $ipv4Chain
Invoke-Adb @('shell', 'iptables', '-F', $ipv4Chain) -IgnoreFailure | Out-Null
Invoke-Adb @('shell', 'iptables', '-X', $ipv4Chain) -IgnoreFailure | Out-Null
Remove-OutputJump 'ip6tables' $ipv6Chain
Invoke-Adb @('shell', 'ip6tables', '-F', $ipv6Chain) -IgnoreFailure | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-X', $ipv6Chain) -IgnoreFailure | Out-Null

if ($Mode -eq 'Allow') {
    Write-Host 'Android emulator internet access is enabled.' -ForegroundColor Green
    Write-Host "LAN hub reachable: $(Test-Address $HubAddress)"
    Write-Host "Public internet reachable: $(Test-Address '8.8.8.8')"
    exit 0
}

Invoke-Adb @('shell', 'iptables', '-N', $ipv4Chain) | Out-Null
Invoke-Adb @('shell', 'iptables', '-A', $ipv4Chain, '-o', 'lo', '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'iptables', '-A', $ipv4Chain, '-d', '10.0.2.0/24', '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'iptables', '-A', $ipv4Chain, '-d', $LanSubnet, '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'iptables', '-A', $ipv4Chain, '-j', 'REJECT') | Out-Null
Invoke-Adb @('shell', 'iptables', '-I', 'OUTPUT', '1', '-j', $ipv4Chain) | Out-Null

Invoke-Adb @('shell', 'ip6tables', '-N', $ipv6Chain) | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-A', $ipv6Chain, '-o', 'lo', '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-A', $ipv6Chain, '-d', 'fe80::/10', '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-A', $ipv6Chain, '-d', 'fc00::/7', '-j', 'RETURN') | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-A', $ipv6Chain, '-j', 'REJECT') | Out-Null
Invoke-Adb @('shell', 'ip6tables', '-I', 'OUTPUT', '1', '-j', $ipv6Chain) | Out-Null

Write-Host "Emulator public internet is blocked; $LanSubnet remains allowed." -ForegroundColor Yellow
$lanReachable = Test-Address $HubAddress
$internetReachable = Test-Address '8.8.8.8'
Write-Host "LAN hub reachable (expected True): $lanReachable"
Write-Host "Public internet reachable (expected False): $internetReachable"
if (-not $lanReachable -or $internetReachable) {
    Write-Warning 'The connectivity result is not safe for an offline test. Restore access with -Mode Allow and check the supplied LAN subnet.'
}
Write-Host 'Restore with: .\tableside-emulator-internet.ps1 -Mode Allow'

