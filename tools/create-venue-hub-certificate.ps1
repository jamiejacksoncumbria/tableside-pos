param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-zA-Z0-9.-]+$')]
  [string]$HubHost,

  [string]$OutputDirectory = '.\build\venue-hub-tls'
)

$ErrorActionPreference = 'Stop'

function Join-DerBytes {
  param([Parameter(Mandatory = $true)][object[]]$Parts)

  $stream = New-Object System.IO.MemoryStream
  try {
    foreach ($part in $Parts) {
      $bytes = [byte[]]$part
      $stream.Write($bytes, 0, $bytes.Length)
    }
    return [byte[]]$stream.ToArray()
  } finally {
    $stream.Dispose()
  }
}

function ConvertTo-DerLength {
  param([Parameter(Mandatory = $true)][int]$Length)

  if ($Length -lt 0) {
    throw 'DER length cannot be negative.'
  }
  if ($Length -lt 128) {
    return [byte[]]@($Length)
  }

  $lengthBytes = New-Object System.Collections.Generic.List[byte]
  $remaining = $Length
  while ($remaining -gt 0) {
    $lengthBytes.Insert(0, [byte]($remaining -band 0xff))
    $remaining = [math]::Floor($remaining / 256)
  }
  return [byte[]](@([byte](0x80 -bor $lengthBytes.Count)) + $lengthBytes.ToArray())
}

function New-DerElement {
  param(
    [Parameter(Mandatory = $true)][byte]$Tag,
    [Parameter(Mandatory = $true)][byte[]]$Value
  )

  return [byte[]](Join-DerBytes @(
    [byte[]]@($Tag),
    [byte[]](ConvertTo-DerLength $Value.Length),
    $Value
  ))
}

function New-DerInteger {
  param([Parameter(Mandatory = $true)][byte[]]$Value)

  $firstNonZero = 0
  while (($firstNonZero -lt ($Value.Length - 1)) -and ($Value[$firstNonZero] -eq 0)) {
    $firstNonZero++
  }
  $unsignedValue = [byte[]]$Value[$firstNonZero..($Value.Length - 1)]
  if (($unsignedValue[0] -band 0x80) -ne 0) {
    $unsignedValue = [byte[]](@(0) + $unsignedValue)
  }
  return [byte[]](New-DerElement 0x02 $unsignedValue)
}

function Export-Pkcs8PrivateKeyPem {
  param([Parameter(Mandatory = $true)][System.Security.Cryptography.RSA]$PrivateKey)

  # Windows PowerShell 5.1 does not expose ExportPkcs8PrivateKeyPem(). Build
  # the same PKCS#8 PrivateKeyInfo structure from portable RSA parameters.
  $parameters = $PrivateKey.ExportParameters($true)
  $rsaPrivateKey = New-DerElement 0x30 (Join-DerBytes @(
    (New-DerInteger ([byte[]]@(0))),
    (New-DerInteger $parameters.Modulus),
    (New-DerInteger $parameters.Exponent),
    (New-DerInteger $parameters.D),
    (New-DerInteger $parameters.P),
    (New-DerInteger $parameters.Q),
    (New-DerInteger $parameters.DP),
    (New-DerInteger $parameters.DQ),
    (New-DerInteger $parameters.InverseQ)
  ))

  # rsaEncryption OID 1.2.840.113549.1.1.1 followed by NULL parameters.
  $rsaAlgorithmIdentifier = [byte[]]@(
    0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
  )
  $privateKeyInfo = New-DerElement 0x30 (Join-DerBytes @(
    (New-DerInteger ([byte[]]@(0))),
    $rsaAlgorithmIdentifier,
    (New-DerElement 0x04 $rsaPrivateKey)
  ))
  $base64 = [Convert]::ToBase64String(
    $privateKeyInfo,
    [Base64FormattingOptions]::InsertLineBreaks
  )
  return "-----BEGIN PRIVATE KEY-----`r`n$base64`r`n-----END PRIVATE KEY-----`r`n"
}

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
  $privateKeyPem = Export-Pkcs8PrivateKeyPem $privateKey
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
