# Smoke: pair a module with Den and check that brand and organisation settings
# flow through, and that pairing again leaves exactly one active credential.
# Registers the module in Den first when it is missing.
# Usage: scripts/smoke-den-pairing.ps1 -Module hr   (hr | stash | events | finance | learn | desk | tasks | wiki)
# Needs the Compose stack with Den and the module running (dev realm, admin/adminadmin).
param([ValidateSet('hr', 'stash', 'events', 'finance', 'learn', 'desk', 'tasks', 'wiki')][string]$Module = 'hr')
$ErrorActionPreference = 'Stop'
$kc = 'http://localhost:8085/realms/conservices/protocol/openid-connect/token'
$den = 'http://localhost:3001'
$targets = @{
  hr      = @{ client = 'hr-spa'; base = 'http://localhost:3003/api'; web = 'http://localhost:3003'; name = 'HR'; internal = 'http://hr-backend:8080' }
  stash   = @{ client = 'stash-spa'; base = 'http://localhost:3000/api'; web = 'http://localhost:3000'; name = 'Stash'; internal = 'http://stash-backend:8080' }
  events  = @{ client = 'events-spa'; base = 'http://localhost:3002/api/v1'; web = 'http://localhost:3002'; name = 'Rally'; internal = 'http://events-backend:8080' }
  finance = @{ client = 'finance-spa'; base = 'http://localhost:3006/api'; web = 'http://localhost:3006'; name = 'Finance'; internal = 'http://finance-backend:8080' }
  learn   = @{ client = 'learn-spa'; base = 'http://localhost:3005/api/v1'; web = 'http://localhost:3005'; name = 'Learn'; internal = 'http://learn-backend:8080' }
  desk    = @{ client = 'desk-spa'; base = 'http://localhost:3008/api/v1'; web = 'http://localhost:3008'; name = 'Desk'; internal = 'http://desk-backend:8080' }
  tasks   = @{ client = 'tasks-spa'; base = 'http://localhost:3009/api/v1'; web = 'http://localhost:3009'; name = 'Tasks'; internal = 'http://tasks-backend:8080' }
  wiki    = @{ client = 'wiki-spa'; base = 'http://localhost:3007/api/v1'; web = 'http://localhost:3007'; name = 'Wiki'; internal = 'http://wiki-backend:8080' }
}
$t = $targets[$Module]

function Get-Token($client) {
  (Invoke-RestMethod -Method Post -Uri $kc -Body @{ grant_type = 'password'; client_id = $client; username = 'admin'; password = 'adminadmin'; scope = 'openid' }).id_token
}
$denH = @{ Authorization = "Bearer $(Get-Token 'den-spa')" }
$modH = @{ Authorization = "Bearer $(Get-Token $t.client)" }

function Get-ModuleBrand {
  $b = Invoke-RestMethod -Uri "$($t.base)/brand"
  # Rally's brand API is camelCase; HR and Stash use snake_case.
  [pscustomobject]@{
    source   = $b.source
    revision = $b.revision
    name     = if ($null -ne $b.organizationName) { $b.organizationName } else { $b.organization_name }
    logo     = if ($null -ne $b.logoUrl) { $b.logoUrl } else { $b.logo_url }
    primary  = $b.theme.primary
  }
}

# 1. The module must be registered in Den; register it when it is missing.
$mod = (Invoke-RestMethod -Uri "$den/api/v1/modules" -Headers $denH) | ForEach-Object { $_ } | Where-Object { $_.slug -eq $Module }
if (-not $mod) {
  $body = @{ slug = $Module; display_name = $t.name; base_url = $t.web; internal_url = $t.internal } | ConvertTo-Json
  $created = Invoke-RestMethod -Method Post -Uri "$den/api/v1/modules" -Headers $denH -ContentType 'application/json' -Body $body
  $mod = Invoke-RestMethod -Uri "$den/api/v1/modules/$($created.id)" -Headers $denH
  Write-Host "Registered $Module in Den (id $($mod.id))"
}

# 2. Pair: mint a URL in Den, redeem it through the module's Den connection API.
$mint = Invoke-RestMethod -Method Post -Uri "$den/api/v1/modules/$($mod.id)/pairing-tokens" -Headers $denH
Write-Host "Den pairing URL minted for $Module"
$status = Invoke-RestMethod -Method Post -Uri "$($t.base)/den/pair" -Headers $modH -ContentType 'application/json' -Body (@{ pairing_url = $mint.pairing_url } | ConvertTo-Json)
if (-not $status.paired -or $status.last_error) { throw "pairing failed: $($status | ConvertTo-Json -Compress)" }
Write-Host "Paired: $($status.den_base_url) synced=$($status.synced_at)"

# Re-pairing revokes every older credential: exactly one is active now.
$active = @((Invoke-RestMethod -Uri "$den/api/v1/modules/$($mod.id)/credentials" -Headers $denH) | ForEach-Object { $_ } | Where-Object { -not $_.revoked_at })
if ($active.Count -ne 1) { throw "want exactly one active credential after pairing, got $($active.Count)" }
Write-Host "One active credential: $($active[0].label)"

# 3. The brand follows Den.
$denBrand = Invoke-RestMethod -Uri "$den/api/v1/public/brand"
$brand = Get-ModuleBrand
if ($brand.source -ne 'den' -or $brand.revision -ne $denBrand.revision -or $brand.name -ne $denBrand.organization_name) {
  throw "module brand does not follow Den: $($brand | ConvertTo-Json -Compress)"
}
if ($brand.primary -ne $denBrand.theme.primary) { throw 'theme primary differs from Den' }
Write-Host "Brand follows Den: revision $($brand.revision), '$($brand.name)', primary $($brand.primary), logo=$([bool]$brand.logo)"

# 4. Organisation settings follow Den: change organization_name, sync the
#    module, check its brand shows the new name, then restore the settings.
$orig = (Invoke-RestMethod -Uri "$den/api/v1/org-settings" -Headers $denH).data
$probe = "Smoke Con $(Get-Date -Format 'HHmmss')"
$changed = @{}
if ($orig) { $orig.PSObject.Properties | ForEach-Object { $changed[$_.Name] = $_.Value } }
$changed['organization_name'] = $probe
try {
  Invoke-RestMethod -Method Put -Uri "$den/api/v1/org-settings" -Headers $denH -ContentType 'application/json' -Body ($changed | ConvertTo-Json -Depth 10) | Out-Null
  $sync = Invoke-RestMethod -Method Post -Uri "$($t.base)/den/sync" -Headers $modH
  if ($sync.last_error) { throw "module sync failed: $($sync.last_error)" }
  $after = Get-ModuleBrand
  if ($after.name -ne $probe) { throw "organisation settings did not reach $Module`: name is '$($after.name)', want '$probe'" }
  Write-Host "Organisation settings follow Den: '$probe'"
} finally {
  $restore = if ($orig) { $orig | ConvertTo-Json -Depth 10 } else { '{}' }
  Invoke-RestMethod -Method Put -Uri "$den/api/v1/org-settings" -Headers $denH -ContentType 'application/json' -Body $restore | Out-Null
  Invoke-RestMethod -Method Post -Uri "$($t.base)/den/sync" -Headers $modH | Out-Null
  Write-Host 'Organisation settings restored'
}
