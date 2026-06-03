# Create a SELF-SIGNED code-signing cert to exercise the signing pipeline
# end-to-end (package.ps1 -> signtool -> release.yml) BEFORE you buy a real cert.
#
# DEV/TEST ONLY: a self-signed cert does NOT clear SmartScreen or reduce AV
# friction for end users — it only proves the pipeline signs, hashes, and verifies
# correctly. Ship with an OV/EV cert (or Azure Trusted Signing); see
# docs/PREPROD-CHECKLIST.md §1.
#
# Usage:
#   ./tool/make-dev-cert.ps1 -Password 'devpass'
# then:
#   $env:VPNAPP_SIGN_PFX  = (Resolve-Path dist/dev-codesign.pfx)
#   $env:VPNAPP_SIGN_PASS = 'devpass'
#   ./tool/package.ps1 -RequireSigning      # full pipeline, signed with the dev cert
# for a CI dry-run, base64 the pfx into the VPNAPP_SIGN_PFX_BASE64 secret:
#   [Convert]::ToBase64String([IO.File]::ReadAllBytes('dist/dev-codesign.pfx')) | Set-Clipboard

param(
  [string]$Password = 'devpass',
  [string]$Subject = 'CN=vpn-app dev (SELF-SIGNED, not for distribution)',
  [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$pfxPath = Join-Path $OutDir 'dev-codesign.pfx'

Write-Host 'Creating a self-signed code-signing certificate...' -ForegroundColor Cyan
# CodeSigningCert preset + the Authenticode EKU; lives in the current user store.
$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject $Subject `
  -KeyUsage DigitalSignature `
  -KeyAlgorithm RSA -KeyLength 3072 `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -NotAfter (Get-Date).AddYears(2)

$securePass = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePass | Out-Null

Write-Host "Exported: $pfxPath" -ForegroundColor Green
Write-Host "Thumbprint: $($cert.Thumbprint)"
Write-Host ''
Write-Host 'Next — exercise the full signing pipeline:' -ForegroundColor Cyan
Write-Host "  `$env:VPNAPP_SIGN_PFX  = (Resolve-Path '$pfxPath')"
Write-Host "  `$env:VPNAPP_SIGN_PASS = '$Password'"
Write-Host '  ./tool/package.ps1 -RequireSigning'
Write-Host ''
Write-Host 'Verify the signature landed on the exe:' -ForegroundColor Cyan
Write-Host '  Get-AuthenticodeSignature .\build\windows\x64\runner\Release\vpn_app.exe | Format-List'
Write-Host ''
Write-Host 'DEV ONLY — replace with an OV/EV cert before distributing.' -ForegroundColor Yellow
