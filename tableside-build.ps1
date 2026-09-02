[CmdletBinding()]
param(
    [ValidateSet(
        'Menu', 'Doctor', 'Dependencies', 'Check', 'Test', 'BuildApk',
        'BuildAppBundle', 'BuildWindows', 'BuildWeb', 'BuildAll',
        'PackageWindows', 'DeployFunctions', 'DeployFirestore',
        'DeployStorage', 'DeployWeb', 'DeployBackend', 'GitStatus',
        'GitPull', 'GitCommit', 'GitPush', 'Clean'
    )]
    [string]$Action = 'Menu',
    [string]$ProjectId = 'table-pos',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:FirebaseDefine = 'TABLESIDE_USE_FIREBASE=true'
Set-Location -LiteralPath $script:RepoRoot

function Write-Heading([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Find-CommandPath([string]$Name, [string[]]$Fallbacks = @()) {
    $command = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    foreach ($candidate in $Fallbacks) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Could not find $Name. Install it or add it to PATH."
}

function Flutter {
    $flutter = Find-CommandPath 'flutter' @(
        'C:\Users\User\Tools\flutter\bin\flutter.bat'
    )
    & $flutter @args
    if ($LASTEXITCODE -ne 0) { throw "Flutter command failed ($LASTEXITCODE)." }
}

function Firebase {
    $firebase = @(Get-Command 'firebase' -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if ($null -ne $firebase) {
        & $firebase.Source @args
    } else {
        $npx = Find-CommandPath 'npx'
        & $npx --yes firebase-tools @args
    }
    if ($LASTEXITCODE -ne 0) { throw "Firebase command failed ($LASTEXITCODE)." }
}

function Invoke-Git([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments) {
    $git = Find-CommandPath 'git'
    & $git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git command failed ($LASTEXITCODE)." }
}

function Confirm-RemoteAction([string]$Message) {
    while ($true) {
        $answer = (Read-Host "$Message [Y]es/[N]o").Trim()
        if ($answer -match '(?i)^(y|yes)$') { return $true }
        if ($answer -match '(?i)^(n|no)$' -or [string]::IsNullOrWhiteSpace($answer)) {
            Write-Host 'Operation cancelled; nothing was deployed.' -ForegroundColor Yellow
            return $false
        }
        Write-Host 'Enter Y, YES, N, or NO.' -ForegroundColor Yellow
    }
}

function Start-OperationLog([string]$Name) {
    $logDirectory = Join-Path $script:RepoRoot 'build-logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDirectory "$stamp-$Name.log"
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    Write-Host "Live output is also being saved to: $logPath" -ForegroundColor DarkGray
    return $logPath
}

function Stop-OperationLog([string]$LogPath, [bool]$Succeeded) {
    try { Stop-Transcript | Out-Null } catch { }
    if ($Succeeded) {
        Write-Host "COMPLETED successfully. Log: $LogPath" -ForegroundColor Green
    } else {
        Write-Host "FAILED. Review log: $LogPath" -ForegroundColor Red
    }
}

function Install-Dependencies {
    Write-Heading 'Flutter dependencies'
    Flutter pub get
    Write-Heading 'Cloud Functions dependencies'
    $npm = Find-CommandPath 'npm'
    Push-Location -LiteralPath (Join-Path $script:RepoRoot 'functions')
    try {
        & $npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

function Invoke-Checks {
    Write-Heading 'Flutter static analysis'
    Flutter analyze
    Write-Heading 'Cloud Functions syntax check'
    $npm = Find-CommandPath 'npm'
    Push-Location -LiteralPath (Join-Path $script:RepoRoot 'functions')
    try {
        & $npm run check
        if ($LASTEXITCODE -ne 0) { throw "Functions check failed ($LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

function Invoke-Tests {
    Write-Heading 'Flutter tests'
    Flutter test
}

function Prepare-Build {
    Flutter pub get
    if (-not $SkipTests) { Invoke-Tests }
}

function Build-Apk {
    Write-Heading 'Android APK (release)'
    Prepare-Build
    Flutter build apk --release --dart-define=$script:FirebaseDefine
    Write-Host "APK: $script:RepoRoot\build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Green
}

function Build-AppBundle {
    Write-Heading 'Android App Bundle (release)'
    Prepare-Build
    Flutter build appbundle --release --dart-define=$script:FirebaseDefine
    Write-Host "Bundle: $script:RepoRoot\build\app\outputs\bundle\release\app-release.aab" -ForegroundColor Green
}

function Build-Windows {
    Write-Heading 'Windows application (release)'
    Prepare-Build
    Flutter build windows --release --dart-define=$script:FirebaseDefine
    Write-Host "Windows build: $script:RepoRoot\build\windows\x64\runner\Release" -ForegroundColor Green
}

function Build-Web {
    Write-Heading 'Web application (release)'
    Prepare-Build
    Flutter build web --release --dart-define=$script:FirebaseDefine
    Write-Host "Web build: $script:RepoRoot\build\web" -ForegroundColor Green
}

function Build-All {
    Write-Heading 'Prepare all release builds'
    Prepare-Build
    Write-Heading 'Android APK (release)'
    Flutter build apk --release --dart-define=$script:FirebaseDefine
    Write-Heading 'Windows application (release)'
    Flutter build windows --release --dart-define=$script:FirebaseDefine
    Write-Heading 'Web application (release)'
    Flutter build web --release --dart-define=$script:FirebaseDefine
    Write-Host 'APK, Windows, and web release builds completed.' -ForegroundColor Green
}

function Package-Windows {
    Build-Windows
    Write-Heading 'Package Windows ZIP'
    $dist = Join-Path $script:RepoRoot 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $versionLine = Select-String -Path (Join-Path $script:RepoRoot 'pubspec.yaml') -Pattern '^version:\s*(.+)$'
    $version = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value.Trim() } else { 'unknown' }
    $safeVersion = $version -replace '[^0-9A-Za-z._+-]', '-'
    $zipPath = Join-Path $dist "tableside-pos-windows-$safeVersion.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
    Compress-Archive -Path (Join-Path $script:RepoRoot 'build\windows\x64\runner\Release\*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Windows ZIP: $zipPath" -ForegroundColor Green
}

function Check-Functions {
    $npm = Find-CommandPath 'npm'
    Push-Location -LiteralPath (Join-Path $script:RepoRoot 'functions')
    try {
        & $npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)." }
        & $npm run check
        if ($LASTEXITCODE -ne 0) { throw "Functions check failed ($LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

function Deploy-Functions {
    if (-not (Confirm-RemoteAction "Deploy Cloud Functions to '$ProjectId'?")) { return }
    Write-Heading "Deploy Cloud Functions to $ProjectId"
    $logPath = Start-OperationLog 'deploy-functions'
    $succeeded = $false
    try {
        Check-Functions
        Firebase deploy --only functions --project $ProjectId
        $succeeded = $true
    } finally {
        Stop-OperationLog $logPath $succeeded
    }
}

function Deploy-Firestore {
    if (-not (Confirm-RemoteAction "Deploy Firestore rules and indexes to '$ProjectId'?")) { return }
    Write-Heading "Deploy Firestore to $ProjectId"
    $logPath = Start-OperationLog 'deploy-firestore'
    $succeeded = $false
    try {
        Firebase deploy --only 'firestore:rules,firestore:indexes' --project $ProjectId
        $succeeded = $true
    } finally {
        Stop-OperationLog $logPath $succeeded
    }
}

function Deploy-Storage {
    if (-not (Confirm-RemoteAction "Deploy Storage rules to '$ProjectId'?")) { return }
    Write-Heading "Deploy Storage rules to $ProjectId"
    $logPath = Start-OperationLog 'deploy-storage'
    $succeeded = $false
    try {
        Firebase deploy --only storage --project $ProjectId
        $succeeded = $true
    } finally {
        Stop-OperationLog $logPath $succeeded
    }
}

function Deploy-Web {
    if (-not (Confirm-RemoteAction "Build and deploy Firebase Hosting to '$ProjectId'?")) { return }
    Write-Heading "Build and deploy Firebase Hosting to $ProjectId"
    $logPath = Start-OperationLog 'deploy-web'
    $succeeded = $false
    try {
        Build-Web
        Firebase deploy --only hosting --project $ProjectId
        $succeeded = $true
    } finally {
        Stop-OperationLog $logPath $succeeded
    }
}

function Deploy-Backend {
    if (-not (Confirm-RemoteAction "Deploy Functions, Firestore, and Storage to '$ProjectId'?")) { return }
    Write-Heading "Deploy backend to $ProjectId"
    $logPath = Start-OperationLog 'deploy-backend'
    $succeeded = $false
    try {
        Check-Functions
        Firebase deploy --only 'functions,firestore:rules,firestore:indexes,storage' --project $ProjectId
        $succeeded = $true
    } finally {
        Stop-OperationLog $logPath $succeeded
    }
}

function Show-GitStatus {
    Write-Heading 'Git status'
    Invoke-Git status --short --branch
    Invoke-Git log -5 --oneline --decorate
}

function Pull-Git {
    Write-Heading 'Pull current branch safely'
    $branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Git is not on a named branch.' }
    Invoke-Git pull --ff-only origin $branch
}

function Commit-Git {
    Show-GitStatus
    Write-Host "`nThis stages tracked file changes only; untracked files are not added." -ForegroundColor Yellow
    $message = Read-Host 'Commit message (leave blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($message)) { return }
    Invoke-Git add --update
    Invoke-Git diff --cached --check
    Invoke-Git commit -m $message
}

function Push-Git {
    $branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Git is not on a named branch.' }
    if (-not (Confirm-RemoteAction "Push branch '$branch' to origin?")) { return }
    Invoke-Git push --set-upstream origin $branch
}

function Clean-Build {
    Write-Host 'Use this only when builds are stale; normal builds do not need flutter clean.' -ForegroundColor Yellow
    if (-not (Confirm-RemoteAction 'Run flutter clean?')) { return }
    Flutter clean
}

function Show-Menu {
    while ($true) {
        Write-Host @'

TableSide POS developer menu
  1  Flutter doctor
  2  Install/update dependencies
  3  Analyze app + check Functions
  4  Run all Flutter tests
  5  Build Android APK
  6  Build Android App Bundle
  7  Build Windows application
  8  Build and ZIP Windows application
  9  Build web application
 10  Build APK + Windows + web
 11  Deploy Cloud Functions
 12  Deploy Firestore rules and indexes
 13  Deploy Storage rules
 14  Build and deploy web hosting
 15  Deploy backend (Functions + Firestore + Storage)
 16  Git status and recent commits
 17  Git pull current branch (fast-forward only)
 18  Git commit tracked changes
 19  Git push current branch
 20  Flutter clean (troubleshooting only)
  0  Exit
'@
        $choice = Read-Host 'Choose an option'
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        try {
            switch ($choice) {
                '1'  { Flutter doctor -v }
                '2'  { Install-Dependencies }
                '3'  { Invoke-Checks }
                '4'  { Invoke-Tests }
                '5'  { Build-Apk }
                '6'  { Build-AppBundle }
                '7'  { Build-Windows }
                '8'  { Package-Windows }
                '9'  { Build-Web }
                '10' { Build-All }
                '11' { Deploy-Functions }
                '12' { Deploy-Firestore }
                '13' { Deploy-Storage }
                '14' { Deploy-Web }
                '15' { Deploy-Backend }
                '16' { Show-GitStatus }
                '17' { Pull-Git }
                '18' { Commit-Git }
                '19' { Push-Git }
                '20' { Clean-Build }
                '0'  { return }
                default { Write-Host 'Choose a number shown in the menu.' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
        if ($choice -ne '0') { Read-Host 'Press Enter to return to the menu' | Out-Null }
    }
}

switch ($Action) {
    'Menu'            { Show-Menu }
    'Doctor'          { Flutter doctor -v }
    'Dependencies'    { Install-Dependencies }
    'Check'           { Invoke-Checks }
    'Test'            { Invoke-Tests }
    'BuildApk'        { Build-Apk }
    'BuildAppBundle'  { Build-AppBundle }
    'BuildWindows'    { Build-Windows }
    'BuildWeb'        { Build-Web }
    'BuildAll'        { Build-All }
    'PackageWindows'  { Package-Windows }
    'DeployFunctions' { Deploy-Functions }
    'DeployFirestore' { Deploy-Firestore }
    'DeployStorage'   { Deploy-Storage }
    'DeployWeb'       { Deploy-Web }
    'DeployBackend'   { Deploy-Backend }
    'GitStatus'       { Show-GitStatus }
    'GitPull'         { Pull-Git }
    'GitCommit'       { Commit-Git }
    'GitPush'         { Push-Git }
    'Clean'           { Clean-Build }
}
