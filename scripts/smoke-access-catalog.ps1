# Smoke: every module's role catalog, HR aggregation, picker → Keycloak groups,
# and Den admin-only API gating.
# Catalogs: Den, HR, Rally (events), Stash, Learn, Finance, Desk, Tasks, Wiki.
# A module that is not running fails the run; skip it with -Skip, for example
#   scripts/smoke-access-catalog.ps1 -Skip desk,tasks
param([string[]]$Skip = @())
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/smoke-lib.ps1"
$kc = "$(Get-SmokeUrl 'KEYCLOAK' 'http://localhost:8085')/realms/conservices/protocol/openid-connect/token"
$hr = Get-SmokeUrl 'HR_API' 'http://localhost:8110'
$den = Get-SmokeUrl 'DEN_API' 'http://localhost:8090'

function Get-AccessToken($client, $user, $pass) {
  $body = @{ grant_type = 'password'; client_id = $client; username = $user; password = $pass; scope = 'openid profile email' }
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).access_token
}

$clients = @{
  den = 'den-spa'; hr = 'hr-spa'; events = 'events-spa'; stash = 'stash-spa'
  learn = 'learn-spa'; finance = 'finance-spa'; desk = 'desk-spa'; tasks = 'tasks-spa'; wiki = 'wiki-spa'
}
$catalogs = [ordered]@{
  den     = "$den/api/role-catalog"
  hr      = "$hr/api/role-catalog"
  events  = "$(Get-SmokeUrl 'EVENTS_API' 'http://localhost:8100')/api/role-catalog"
  stash   = "$(Get-SmokeUrl 'STASH_API' 'http://localhost:8088')/api/role-catalog"
  learn   = "$(Get-SmokeUrl 'LEARN_API' 'http://localhost:8120')/api/role-catalog"
  finance = "$(Get-SmokeUrl 'FINANCE_API' 'http://localhost:8130')/api/role-catalog"
  desk    = "$(Get-SmokeUrl 'DESK_API' 'http://localhost:8150')/api/role-catalog"
  tasks   = "$(Get-SmokeUrl 'TASKS_API' 'http://localhost:8160')/api/role-catalog"
  wiki    = "$(Get-SmokeUrl 'WIKI_API' 'http://localhost:8140')/api/role-catalog"
}
$staff = @{ Authorization = "Bearer $(Get-AccessToken 'hr-spa' 'admin' 'adminadmin')" }
foreach ($slug in $catalogs.Keys) {
  if ($Skip -contains $slug) { Write-Host ("{0,-7} skipped" -f $slug); continue }
  # The catalog contract allows HR's service token or a staff sign-in; try
  # without first, as older modules serve it openly.
  try { $c = Invoke-RestMethod $catalogs[$slug] }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw "$slug catalog: $($_.Exception.Message)" }
    $signedIn = @{ Authorization = "Bearer $(Get-AccessToken $clients[$slug] 'admin' 'adminadmin')" }
    $c = Invoke-RestMethod $catalogs[$slug] -Headers $signedIn
  }
  if (-not $c.roles) { throw "$slug catalog lists no roles" }
  $assignable = @($c.roles | Where-Object assignable).Count
  Write-Host ("{0,-7} {1} roles ({2} assignable)" -f $c.module, @($c.roles).Count, $assignable)
}

$h = $staff
$agg = Invoke-RestMethod "$hr/api/access-catalog" -Headers $h
foreach ($m in $agg.modules) { Write-Host "HR sees: $($m.module) status=$($m.status) $($m.error)" }

$stash = $agg.modules | Where-Object module -eq 'stash'
if (-not $stash -or $Skip -contains 'stash') { Write-Host 'Stash not in HR catalog: provisioning check skipped' }
else {
  $role = $stash.roles | Where-Object { $_.key -eq 'conops_lead' }
  $stamp = Get-Date -Format 'HHmmss'
  $person = Invoke-RestMethod -Method Post -Uri "$hr/api/people" -Headers $h -ContentType 'application/json' -Body (@{
    first_name = 'Picker'; last_name = "$stamp"; nickname = "picker$stamp"; date_of_birth = '1992-03-04'
    email = "picker$stamp@conservices.local"; phone = '+43 660 1111111'
    address = @{ street = '2 Example Street'; postal_code = '1010'; city = 'Vienna'; country = 'AT' }
    emergency_contact = @{ name = 'Someone'; phone = '+43 660 2222222' }
  } | ConvertTo-Json -Depth 4)
  $draft = Invoke-RestMethod -Method Post -Uri "$hr/api/drafts" -Headers $h -ContentType 'application/json' -Body (@{ person_id = $person.id; title = 'ConOps' } | ConvertTo-Json)
  Invoke-RestMethod -Method Put -Uri "$hr/api/drafts/$($draft.id)/roles" -Headers $h -ContentType 'application/json' -Body (@{
    roles = @(@{ role_name = "stash:$($role.key)"; group_name = $role.group; scope = $role.scope })
  } | ConvertTo-Json -Depth 4) | Out-Null
  Invoke-RestMethod -Method Post -Uri "$hr/api/drafts/$($draft.id)/provision" -Headers $h | Out-Null
  $idp = (Invoke-RestMethod "$hr/api/drafts/$($draft.id)/provisioning-jobs" -Headers $h).items | Where-Object target -eq 'idp' | Select-Object -First 1
  Write-Host "Provision stash:conops_lead → group $($role.group): $($idp.status) $($idp.message -replace 'temporary_password=.*','(temp pw issued)')"
  if ($idp.status -ne 'succeeded') { throw 'provision failed' }
}

$bob = @{ Authorization = "Bearer $(Get-AccessToken 'den-spa' 'bob' 'bobbob')" }
try { Invoke-RestMethod "$den/api/v1/modules" -Headers $bob | Out-Null; throw 'bob should be forbidden' }
catch { if ($_.Exception.Response.StatusCode.value__ -eq 403) { Write-Host 'Den admin API as member: 403 OK' } else { throw } }
$dash = Invoke-RestMethod "$den/api/v1/dashboard" -Headers $bob
Write-Host "Den dashboard as member includes brand: $([bool]$dash.brand) primary=$($dash.brand.theme.primary)"
