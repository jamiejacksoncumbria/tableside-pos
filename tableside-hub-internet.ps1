[CmdletBinding()]
param(
    [ValidateSet('Block', 'Allow')]
    [string]$Mode = 'Block',

    [string]$AppPath
)

$ErrorActionPreference = 'Stop'
$ipv4Rule = 'TableSideCY TEST - Hub public IPv4 blocked'
$ipv6Rule = 'TableSideCY TEST - Hub public IPv6 blocked'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator before using this script.'
    }
}

function Resolve-TableSideExecutable {
    if ($AppPath) {
        return (Resolve-Path -LiteralPath $AppPath).Path
    }

    $running = Get-CimInstance Win32_Process -Filter "Name='TableSideCY.exe'" |
        Select-Object -First 1 -ExpandProperty ExecutablePath
    if ($running) {
        return ([string]$running).Trim().Trim('"')
    }

    $candidates = @(
        (Join-Path $PSScriptRoot 'build\windows\x64\runner\Debug\TableSideCY.exe'),
        (Join-Path $PSScriptRoot 'build\windows\x64\runner\Release\TableSideCY.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'TableSideCY.exe is not running and no Debug/Release build was found. Supply -AppPath explicitly.'
}

Assert-Administrator

# Remove only rules owned by this test script. This makes both modes
# repeatable and avoids accumulating stale rules after rebuilding the app.
Get-NetFirewallRule -DisplayName $ipv4Rule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName $ipv6Rule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

if ($Mode -eq 'Allow') {
    Write-Host 'TableSideCY hub internet access is enabled.' -ForegroundColor Green
    exit 0
}

$resolvedAppPath = Resolve-TableSideExecutable

# Block every IPv4 range except loopback, link-local and the three private LAN
# ranges. Explicit ranges are used because the Windows "Internet" keyword can
# classify a local subnet as public on some Wi-Fi/router configurations.
$publicIpv4 = @(
    '0.0.0.0-9.255.255.255',
    '11.0.0.0-126.255.255.255',
    '128.0.0.0-169.253.255.255',
    '169.255.0.0-172.15.255.255',
    '172.32.0.0-192.167.255.255',
    '192.169.0.0-255.255.255.255'
)

New-NetFirewallRule `
    -DisplayName $ipv4Rule `
    -Direction Outbound `
    -Action Block `
    -Profile Any `
    -Program $resolvedAppPath `
    -RemoteAddress $publicIpv4 | Out-Null

# Global-unicast IPv6 is internet-routable. Loopback, link-local and private
# unique-local IPv6 remain untouched so local venue traffic still works.
New-NetFirewallRule `
    -DisplayName $ipv6Rule `
    -Direction Outbound `
    -Action Block `
    -Profile Any `
    -Program $resolvedAppPath `
    -RemoteAddress '2000::/3' | Out-Null

Write-Host "Public internet is blocked for $resolvedAppPath" -ForegroundColor Yellow
Write-Host 'Private LAN, loopback and link-local traffic remain available.'
Write-Host 'Restore with: .\tableside-hub-internet.ps1 -Mode Allow'

