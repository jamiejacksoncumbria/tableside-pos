[CmdletBinding()]
param(
    [string]$KeystorePath = (Join-Path $env:USERPROFILE '.tablesidecy\android-upload-keystore.jks'),
    [string]$Alias = 'tablesidecy-upload'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$propertiesPath = Join-Path $repoRoot 'android\key.properties'
$resolvedKeystorePath = [System.IO.Path]::GetFullPath($KeystorePath)

if (Test-Path -LiteralPath $resolvedKeystorePath) {
    throw "Refusing to overwrite the existing keystore: $resolvedKeystorePath"
}
if (Test-Path -LiteralPath $propertiesPath) {
    throw "Refusing to overwrite the existing signing configuration: $propertiesPath"
}

$keytool = Get-Command keytool -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $keytool) {
    $javaHomeKeytool = if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $null
    } else {
        Join-Path $env:JAVA_HOME 'bin\keytool.exe'
    }
    if ($null -eq $javaHomeKeytool -or -not (Test-Path -LiteralPath $javaHomeKeytool)) {
        throw 'keytool was not found. Install a JDK or set JAVA_HOME, then retry.'
    }
    $keytoolPath = $javaHomeKeytool
} else {
    $keytoolPath = $keytool.Source
}

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($resolvedKeystorePath)) |
    Out-Null

Write-Host 'Keytool will ask for the keystore password and certificate identity.' -ForegroundColor Cyan
Write-Host 'Use a unique strong password and save it in a password manager.' -ForegroundColor Yellow
& $keytoolPath -genkeypair -v -keystore $resolvedKeystorePath -alias $Alias `
    -keyalg RSA -keysize 4096 -validity 10000
if ($LASTEXITCODE -ne 0) {
    throw "keytool failed ($LASTEXITCODE); no signing configuration was written."
}

# Java properties treat backslashes as escapes. Forward slashes work on Windows
# and avoid silently changing the keystore path during Gradle configuration.
$portablePath = $resolvedKeystorePath.Replace('\', '/')
$properties = @(
    '# Generated locally. Never commit this file or the keystore.'
    "storeFile=$portablePath"
    "keyAlias=$Alias"
    ''
    '# Supply passwords in the shell before a release build:'
    '# TABLESIDECY_ANDROID_STORE_PASSWORD'
    '# TABLESIDECY_ANDROID_KEY_PASSWORD'
) -join [Environment]::NewLine
[System.IO.File]::WriteAllText($propertiesPath, $properties + [Environment]::NewLine)

Write-Host "Created private keystore: $resolvedKeystorePath" -ForegroundColor Green
Write-Host "Created ignored configuration: $propertiesPath" -ForegroundColor Green
Write-Host 'Back up the keystore and passwords separately before publishing any build.' -ForegroundColor Yellow
