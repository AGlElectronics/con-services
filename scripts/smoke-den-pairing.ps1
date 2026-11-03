# Smoke: pair a module with Den and check brand + org settings flow through.
# Usage: scripts/smoke-den-pairing.ps1 -Module hr   (hr | stash | events)
param([ValidateSet('hr', 'stash', 'events')][string]$Module = 'hr')
$ErrorActionPreference = 'Stop'
$kc = 'http://localhost:8085/realms/conservices/protocol/openid-connect/token'
$den = 'http://localhost:3001'
$targets = @{
  hr     = @{ client = 'hr-spa'; base = 'http://localhost:3003/api' }
  stash  = @{ client = 'stash-spa'; base = 'http://localhost:3000/api' }
  events = @{ client = 'events-spa'; base = 'http://localhost:3002/api/v1' }
}
$t = $targets[$Module]

function Get-Token($client) {
  (Invoke-RestMethod -Method Post -Uri $kc -Body @{ grant_type = 'password'; client_id = $client; username = 'admin'; password = 'adminadmin'; scope = 'openid' }).id_token
}
$denH = @{ Authorization = "Bearer $(Get-Token 'den-spa')" }
$modH = @{ Authorization = "Bearer $(Get-Token $t.client)" }

$mod = (Invoke-RestMethod -Uri "$den/api/v1/modules" -Headers $denH) | ForEach-Object { $_ } | Where-Object { $_.slug -eq $Module }
if (-not $mod) { throw "module $Module is not registered in Den" }
$mint = Invoke-RestMethod -Method Post -Uri "$den/api/v1/modules/$($mod.id)/pairing-tokens" -Headers $denH
Write-Host "Den pairing URL minted for $Module"

$status = Invoke-RestMethod -Method Post -Uri "$($t.base)/den/pair" -Headers $modH -ContentType 'application/json' -Body (@{ pairing_url = $mint.pairing_url } | ConvertTo-Json)
if (-not $status.paired -or $status.last_error) { throw "pairing failed: $($status | ConvertTo-Json -Compress)" }
Write-Host "Paired: $($status.den_base_url) synced=$($status.synced_at)"

$denBrand = Invoke-RestMethod -Uri "$den/api/v1/public/brand"
$brand = Invoke-RestMethod -Uri "$($t.base)/brand"
# Rally's brand API is camelCase; HR and Stash use snake_case.
$orgName = if ($null -ne $brand.organizationName) { $brand.organizationName } else { $brand.organization_name }
$logo = if ($null -ne $brand.logoUrl) { $brand.logoUrl } else { $brand.logo_url }
if ($brand.source -ne 'den' -or $brand.revision -ne $denBrand.revision -or $orgName -ne $denBrand.organization_name) {
  throw "module brand does not follow Den: $($brand | ConvertTo-Json -Compress)"
}
if ($brand.theme.primary -ne $denBrand.theme.primary) { throw 'theme primary differs from Den' }
Write-Host "Brand follows Den: revision $($brand.revision), '$orgName', primary $($brand.theme.primary), logo=$([bool]$logo)"
