# Shared by the smoke scripts (dot-source it: . "$PSScriptRoot/smoke-lib.ps1").
# Addresses default to the Docker Compose dev stack; the nightly smoke
# workflow (kind cluster) overrides them with SMOKE_* environment variables:
#
#   SMOKE_KEYCLOAK   Keycloak base URL (token endpoint and admin API)
#   SMOKE_DEN_API    SMOKE_HR_API     SMOKE_STASH_API   SMOKE_EVENTS_API
#   SMOKE_LEARN_API  SMOKE_FINANCE_API SMOKE_WIKI_API   SMOKE_DESK_API
#   SMOKE_TASKS_API  SMOKE_TASKS_WEB  backend and web app base URLs
#   SMOKE_INSECURE=1 accept self-signed certificates (PowerShell 7 only)
#
# Docs: https://aglelectronics.github.io/con-services/contributing/ci/#smoke-tests

function Get-SmokeUrl([string]$Name, [string]$Default) {
  $v = [Environment]::GetEnvironmentVariable("SMOKE_$Name")
  if ($v) { return $v.TrimEnd('/') }
  return $Default
}

if ($env:SMOKE_INSECURE -eq '1') {
  if ($PSVersionTable.PSVersion.Major -lt 6) { throw 'SMOKE_INSECURE=1 needs PowerShell 7 (pwsh)' }
  $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
  $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
}

# Windows PowerShell aliases "curl" to Invoke-WebRequest, so call curl.exe there.
$SmokeCurl = if ($IsLinux -or $IsMacOS) { 'curl' } else { 'curl.exe' }
$SmokeCurlArgs = if ($env:SMOKE_INSECURE -eq '1') { @('-k') } else { @() }
