param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-zA-Z0-9.-]+$')]
  [string]$HubHost,

  [string]$OutputDirectory = '.\build\venue-hub-tls'
)

$ErrorActionPreference = 'Stop'
$resolvedOutput = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputDirectory))
$workspace = [System.IO.Path]::GetFullPath((Get-Location).Path)
if (-not $resolvedOutput.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'OutputDirectory must remain inside the current TableSide workspace.'
}
[System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$certificate = New-SelfSignedCertificate `
  -DnsName $HubHost `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -KeyAlgorithm RSA `
  -KeyLength 3072 `
  -HashAlgorithm SHA256 `
  -KeyExportPolicy Exportable `
  -NotAfter (Get-Date).AddYears(3) `
  -FriendlyName "TableSide venue hub $HubHost"

$certificateBytes = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$certificateBase64 = [Convert]::ToBase64String($certificateBytes, [Base64FormattingOptions]::InsertLineBreaks)
$certificatePem = "-----BEGIN CERTIFICATE-----`r`n$certificateBase64`r`n-----END CERTIFICATE-----`r`n"
$privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
try {
  $privateKeyPem = $privateKey.ExportPkcs8PrivateKeyPem()
} finally {
  $privateKey.Dispose()
}

$certificatePath = Join-Path $resolvedOutput 'venue-hub-certificate.pem'
$privateKeyPath = Join-Path $resolvedOutput 'venue-hub-private-key.pem'
[System.IO.File]::WriteAllText($certificatePath, $certificatePem, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($privateKeyPath, $privateKeyPem, [System.Text.UTF8Encoding]::new($false))

$rootStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
  [System.Security.Cryptography.X509Certificates.StoreName]::Root,
  [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
)
try {
  $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  $rootStore.Add($certificate)
} finally {
  $rootStore.Close()
}

Write-Host "Created and trusted the TableSide venue certificate for $HubHost."
Write-Host "Certificate PEM: $certificatePath"
Write-Host "Private key PEM: $privateKeyPath"
Write-Warning 'Install venue-hub-certificate.pem as a trusted CA/certificate on every Android, iOS, Windows or browser device that connects to this hub.'
Write-Warning 'Keep venue-hub-private-key.pem only on the hub. Delete the exported copy after importing it into TableSide.'
