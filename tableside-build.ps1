[CmdletBinding()]
param(
    [ValidateSet(
        'Menu', 'Doctor', 'Dependencies', 'Check', 'Test', 'BuildApk',
        'BuildAppBundle', 'BuildWindows', 'BuildWeb', 'BuildAll',
        'PackageWindows', 'DeployFunctions', 'DeployFirestore',
        'DeployStorage', 'DeployWeb', 'DeployBackend', 'GitStatus',
        'GitPull', 'GitCommit', 'GitPush', 'ShorebirdDoctor',
        'ShorebirdReleaseAndroid', 'ShorebirdPatchAndroid',
        'ShorebirdReleaseWindows', 'ShorebirdPatchWindows', 'Clean'
    )]
    [string]$Action = 'Menu',
    [ValidateSet('Staging', 'Production')]
    [string]$Environment = 'Staging',
    [string]$ProjectId = '',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $script:RepoRoot

$environmentName = $Environment.ToLowerInvariant()
if ($environmentName -eq 'staging') {
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { $ProjectId = 'table-pos' }
    if ($ProjectId -ne 'table-pos') {
        throw "Staging is locked to Firebase project 'table-pos'."
    }
    $script:DartDefineFile = Join-Path $script:RepoRoot 'config\firebase-staging.json'
} else {
    $script:DartDefineFile = Join-Path $script:RepoRoot 'config\firebase-production.json'
    if (-not (Test-Path -LiteralPath $script:DartDefineFile)) {
        throw 'Production is not configured. Copy config/firebase-production.example.json to config/firebase-production.json and add the real production Firebase identifiers.'
    }
    $productionConfig = Get-Content -Raw -LiteralPath $script:DartDefineFile | ConvertFrom-Json
    if ([string]$productionConfig.TABLESIDE_ENVIRONMENT -ne 'production' -or
        $productionConfig.TABLESIDE_USE_FIREBASE -ne $true) {
        throw 'Production configuration must enable Firebase and set TABLESIDE_ENVIRONMENT to production.'
    }
    $configuredProject = [string]$productionConfig.TABLESIDE_PRODUCTION_FIREBASE_PROJECT_ID
    if ([string]::IsNullOrWhiteSpace($configuredProject) -or $configuredProject -eq 'table-pos' -or $configuredProject -like 'REPLACE_*') {
        throw 'The production Firebase project ID is missing or still points at staging.'
    }
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { $ProjectId = $configuredProject }
    if ($ProjectId -ne $configuredProject) {
        throw "ProjectId '$ProjectId' does not match production configuration '$configuredProject'."
    }
    $requiredProductionKeys = @(
        'TABLESIDE_PRODUCTION_FIREBASE_MESSAGING_SENDER_ID',
        'TABLESIDE_PRODUCTION_FIREBASE_STORAGE_BUCKET',
        'TABLESIDE_PRODUCTION_FIREBASE_AUTH_DOMAIN',
        'TABLESIDE_PRODUCTION_FIREBASE_WEB_API_KEY',
        'TABLESIDE_PRODUCTION_FIREBASE_WEB_APP_ID',
        'TABLESIDE_PRODUCTION_FIREBASE_WINDOWS_API_KEY',
        'TABLESIDE_PRODUCTION_FIREBASE_WINDOWS_APP_ID',
        'TABLESIDE_PRODUCTION_FIREBASE_ANDROID_API_KEY',
        'TABLESIDE_PRODUCTION_FIREBASE_ANDROID_APP_ID',
        'TABLESIDE_PRODUCTION_FIREBASE_IOS_API_KEY',
        'TABLESIDE_PRODUCTION_FIREBASE_IOS_APP_ID'
    )
    foreach ($key in $requiredProductionKeys) {
        $value = [string]$productionConfig.$key
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Production Firebase setting '$key' is missing."
        }
    }
}
$script:EnvironmentName = $environmentName
$script:FirebaseBuildArgument = "--dart-define-from-file=$($script:DartDefineFile)"

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
    if ($script:EnvironmentName -eq 'production') {
        Write-Host "PRODUCTION deployment selected: $ProjectId" -ForegroundColor Red
        $confirmation = (Read-Host "Type the production project ID '$ProjectId' to continue").Trim()
        if ($confirmation -ne $ProjectId) {
            Write-Host 'Production operation cancelled; the project ID did not match.' -ForegroundColor Yellow
            return $false
        }
    }
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
    Write-Host "Environment: $($script:EnvironmentName.ToUpperInvariant()) | Firebase project: $ProjectId" -ForegroundColor Yellow
    Flutter pub get
    if (-not $SkipTests) { Invoke-Tests }
}

function Invoke-Shorebird([string[]]$Arguments) {
    $shorebird = Find-CommandPath 'shorebird'
    $global:LASTEXITCODE = 0
    & $shorebird @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Shorebird command failed ($exitCode)." }
}

function Assert-ShorebirdReady {
    if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'shorebird.yaml'))) {
        throw 'Shorebird is not initialized. Install/login to Shorebird, run shorebird init once, and commit the generated shorebird.yaml.'
    }
    Invoke-Shorebird -Arguments @('doctor')
}

function Invoke-WithAndroidNativeFirebaseConfig([scriptblock]$Operation) {
    if ($script:EnvironmentName -eq 'staging') {
        & $Operation
        return
    }

    $productionGoogleServices = Join-Path $script:RepoRoot 'config\firebase-production\google-services.json'
    if (-not (Test-Path -LiteralPath $productionGoogleServices)) {
        throw 'Production Android build requires config/firebase-production/google-services.json from the production Firebase project.'
    }
    $nativeConfig = Get-Content -Raw -LiteralPath $productionGoogleServices | ConvertFrom-Json
    if ([string]$nativeConfig.project_info.project_id -ne $ProjectId) {
        throw 'Production google-services.json does not match the selected production Firebase project.'
    }

    $androidConfig = Join-Path $script:RepoRoot 'android\app\google-services.json'
    $backupConfig = Join-Path ([System.IO.Path]::GetTempPath()) "tableside-staging-google-services-$([guid]::NewGuid()).json"
    Copy-Item -LiteralPath $androidConfig -Destination $backupConfig -Force
    try {
        Copy-Item -LiteralPath $productionGoogleServices -Destination $androidConfig -Force
        & $Operation
    } finally {
        Copy-Item -LiteralPath $backupConfig -Destination $androidConfig -Force
        Remove-Item -LiteralPath $backupConfig -Force
    }
}

function Invoke-AndroidBuild([string]$Target) {
    Invoke-WithAndroidNativeFirebaseConfig {
        Flutter build $Target --release $script:FirebaseBuildArgument
    }
}

function Build-Apk {
    Write-Heading 'Android APK (release)'
    Prepare-Build
    Invoke-AndroidBuild 'apk'
    Write-Host "APK: $script:RepoRoot\build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Green
}

function Build-AppBundle {
    Write-Heading 'Android App Bundle (release)'
    Prepare-Build
    Invoke-AndroidBuild 'appbundle'
    Write-Host "Bundle: $script:RepoRoot\build\app\outputs\bundle\release\app-release.aab" -ForegroundColor Green
}

function Build-Windows {
    Write-Heading 'Windows application (release)'
    Prepare-Build
    Flutter build windows --release $script:FirebaseBuildArgument
    Write-Host "Windows build: $script:RepoRoot\build\windows\x64\runner\Release" -ForegroundColor Green
}

function Build-Web {
    Write-Heading 'Web application (release)'
    Prepare-Build
    Flutter build web --release $script:FirebaseBuildArgument
    Write-Host "Web build: $script:RepoRoot\build\web" -ForegroundColor Green
}

function Build-All {
    Write-Heading 'Prepare all release builds'
    Prepare-Build
    Write-Heading 'Android APK (release)'
    Invoke-AndroidBuild 'apk'
    Write-Heading 'Windows application (release)'
    Flutter build windows --release $script:FirebaseBuildArgument
    Write-Heading 'Web application (release)'
    Flutter build web --release $script:FirebaseBuildArgument
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
    $zipPath = Join-Path $dist "tablesidecy-windows-$safeVersion.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
    Compress-Archive -Path (Join-Path $script:RepoRoot 'build\windows\x64\runner\Release\*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Windows ZIP: $zipPath" -ForegroundColor Green
}

function Invoke-ShorebirdRelease([string]$Platform, [bool]$Patch) {
    Assert-ShorebirdReady
    Prepare-Build
    $operation = if ($Patch) { 'patch' } else { 'release' }
    $publicKey = [string]$env:SHOREBIRD_PUBLIC_KEY_PATH
    if ([string]::IsNullOrWhiteSpace($publicKey) -or -not (Test-Path -LiteralPath $publicKey)) {
        throw 'Set SHOREBIRD_PUBLIC_KEY_PATH to the secured Shorebird RSA public PEM before creating a release or patch.'
    }
    $signingArguments = @('--public-key-path', $publicKey)
    if ($Patch) {
        $privateKey = [string]$env:SHOREBIRD_PRIVATE_KEY_PATH
        if ([string]::IsNullOrWhiteSpace($privateKey) -or -not (Test-Path -LiteralPath $privateKey)) {
            throw 'Set SHOREBIRD_PRIVATE_KEY_PATH to the secured Shorebird RSA private PEM before creating a patch.'
        }
        $signingArguments += @('--private-key-path', $privateKey)
        if ($script:EnvironmentName -eq 'staging') {
            $signingArguments += @('--track', 'staging')
        }
    }
    Write-Heading "Shorebird $operation for $Platform"
    # PowerShell must pass the Flutter argument separator as one literal
    # argument. Building the complete array first prevents it from being
    # reinterpreted as a PowerShell or Shorebird short option (for example
    # `-e`) when this operation runs inside the Android configuration block.
    $shorebirdArguments = @($operation, $Platform)
    $shorebirdArguments += $signingArguments
    $shorebirdArguments += @('--', $script:FirebaseBuildArgument)
    $startedAtUtc = [DateTime]::UtcNow
    if ($Platform -eq 'android') {
        Invoke-WithAndroidNativeFirebaseConfig {
            Invoke-Shorebird -Arguments $shorebirdArguments
        }
    } else {
        Invoke-Shorebird -Arguments $shorebirdArguments
    }
    if (-not $Patch) {
        $artifact = switch ($Platform) {
            'android' { Join-Path $script:RepoRoot 'build\app\outputs\bundle\release\app-release.aab' }
            'windows' { Join-Path $script:RepoRoot 'build\windows\x64\runner\Release\tableside_pos.exe' }
            default { $null }
        }
        if ($null -ne $artifact) {
            if (-not (Test-Path -LiteralPath $artifact)) {
                throw "Shorebird returned without creating the expected $Platform release artifact: $artifact"
            }
            $artifactInfo = Get-Item -LiteralPath $artifact
            if ($artifactInfo.LastWriteTimeUtc -lt $startedAtUtc.AddSeconds(-5)) {
                throw "Shorebird did not refresh the expected $Platform release artifact. Refusing to report a stale build as successful."
            }
        }
    }
    if ($Patch) {
        Write-Host 'Patch uploaded. Promote it through a test track before stable production rollout.' -ForegroundColor Green
    } else {
        Write-Host 'Shorebird baseline created. Distribute this exact generated build; stock Flutter builds cannot receive its patches.' -ForegroundColor Green
    }
}

function Shorebird-ReleaseAndroid { Invoke-ShorebirdRelease 'android' $false }
function Shorebird-PatchAndroid { Invoke-ShorebirdRelease 'android' $true }
function Shorebird-ReleaseWindows { Invoke-ShorebirdRelease 'windows' $false }
function Shorebird-PatchWindows { Invoke-ShorebirdRelease 'windows' $true }

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
        Write-Host "`nEnvironment: $($script:EnvironmentName.ToUpperInvariant()) | Firebase: $ProjectId" -ForegroundColor Yellow
        Write-Host @'

TableSideCY developer menu
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
 20  Shorebird doctor
 21  Shorebird Android release baseline
 22  Shorebird Android patch
 23  Shorebird Windows release baseline
 24  Shorebird Windows patch
 25  Flutter clean (troubleshooting only)
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
                '20' { Assert-ShorebirdReady }
                '21' { Shorebird-ReleaseAndroid }
                '22' { Shorebird-PatchAndroid }
                '23' { Shorebird-ReleaseWindows }
                '24' { Shorebird-PatchWindows }
                '25' { Clean-Build }
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
    'ShorebirdDoctor' { Assert-ShorebirdReady }
    'ShorebirdReleaseAndroid' { Shorebird-ReleaseAndroid }
    'ShorebirdPatchAndroid' { Shorebird-PatchAndroid }
    'ShorebirdReleaseWindows' { Shorebird-ReleaseWindows }
    'ShorebirdPatchWindows' { Shorebird-PatchWindows }
    'Clean'           { Clean-Build }
}
