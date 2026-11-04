# Local DNS + HTTPS trust for https://<app>.conservices.test (run as Administrator).
#   scripts/setup-local-dns.ps1          add hosts entries, trust the proxy's root CA
#   scripts/setup-local-dns.ps1 -Remove  undo both
# The proxy container must be running (docker compose up -d proxy) for the CA step.
param([switch]$Remove)
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an elevated PowerShell (Run as administrator).'
}

$names = 'auth', 'den', 'hr', 'stash', 'events', 'mail', 's3' | ForEach-Object { "$_.conservices.test" }
$hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
$begin = '# >>> conservices local DNS'
$end = '# <<< conservices local DNS'
$certName = 'Caddy Local Authority'

# Drop any previous block, then (unless removing) append a fresh one.
$lines = Get-Content $hostsFile
$kept = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($l in $lines) {
  if ($l -eq $begin) { $skip = $true; continue }
  if ($l -eq $end) { $skip = $false; continue }
  if (-not $skip) { $kept.Add($l) }
}
if (-not $Remove) {
  $kept.Add($begin)
  foreach ($n in $names) { $kept.Add("127.0.0.1`t$n") }
  $kept.Add($end)
}
Set-Content -Path $hostsFile -Value $kept -Encoding ASCII
ipconfig /flushdns | Out-Null
Write-Host ($(if ($Remove) { 'Removed hosts entries.' } else { "Hosts entries: $($names -join ', ')" }))

# Trust (or untrust) the proxy's local root CA.
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*$certName*" } | ForEach-Object {
  Remove-Item $_.PSPath
  Write-Host "Removed old trusted CA $($_.Thumbprint)"
}
if (-not $Remove) {
  $tmp = Join-Path $env:TEMP 'conservices-local-root.crt'
  docker cp conservices-proxy:/data/caddy/pki/authorities/local/root.crt $tmp
  if ($LASTEXITCODE -ne 0) { throw 'Could not copy the CA from conservices-proxy. Is it running? (docker compose up -d proxy)' }
  $cert = Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root
  Write-Host "Trusted proxy CA $($cert.Thumbprint). Restart your browser."
  Write-Host 'Firefox: set security.enterprise_roots.enabled = true in about:config to use the Windows store.'
}
