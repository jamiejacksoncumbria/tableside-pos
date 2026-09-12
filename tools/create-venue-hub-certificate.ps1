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

$parsedAddress = $null
$subjectAlternativeName = if (
  [System.Net.IPAddress]::TryParse($HubHost, [ref]$parsedAddress)
) {
  "IPAddress=$HubHost"
} else {
  "DNS=$HubHost"
}

# This deliberately creates a venue-specific private trust anchor that is also
# the hub's server certificate. Android's CA installer rejects ordinary
# self-signed leaf certificates, so CA basic constraints are required. The
# private key remains only on the hub and every request is also device-signed.
$certificateParameters = @{
  Type = 'Custom'
  Subject = "CN=$HubHost"
  CertStoreLocation = 'Cert:\CurrentUser\My'
  KeyAlgorithm = 'RSA'
  KeyLength = 3072
  HashAlgorithm = 'SHA256'
  KeyExportPolicy = 'Exportable'
  KeyUsage = @('CertSign', 'DigitalSignature', 'KeyEncipherment')
  TextExtension = @(
    '2.5.29.19={critical}{text}ca=true&pathlength=0',
    '2.5.29.37={text}1.3.6.1.5.5.7.3.1',
    "2.5.29.17={text}$subjectAlternativeName"
  )
  NotAfter = (Get-Date).AddYears(3)
  FriendlyName = "TableSide venue hub $HubHost"
}
$certificate = New-SelfSignedCertificate @certificateParameters

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
$certificateDerPath = Join-Path $resolvedOutput 'venue-hub-trust-certificate.cer'
$privateKeyPath = Join-Path $resolvedOutput 'venue-hub-private-key.pem'
[System.IO.File]::WriteAllText($certificatePath, $certificatePem, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllBytes($certificateDerPath, $certificateBytes)
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
Write-Host "Android/iOS trust certificate: $certificateDerPath"
Write-Host "Private key PEM: $privateKeyPath"
Write-Warning 'Install venue-hub-trust-certificate.cer as a trusted CA on every Android or iOS device that connects to this hub. On iOS, also enable full trust for it.'
Write-Warning 'Keep venue-hub-private-key.pem only on the hub. Delete the exported copy after importing it into TableSide.'
