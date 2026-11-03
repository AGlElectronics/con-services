# Smoke: every module's role catalog, HR aggregation, picker → Keycloak groups,
# and Den admin-only API gating.
$ErrorActionPreference = 'Stop'
$kc = 'http://localhost:8085/realms/conservices/protocol/openid-connect/token'
$hr = 'http://localhost:8110'

function Get-IdToken($client, $user, $pass) {
  $body = @{ grant_type = 'password'; client_id = $client; username = $user; password = $pass; scope = 'openid profile email' }
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).id_token
}

foreach ($u in 'http://localhost:8088/api/role-catalog', 'http://localhost:8090/api/role-catalog', 'http://localhost:8100/api/role-catalog', "$hr/api/role-catalog") {
  $c = Invoke-RestMethod $u
  $assignable = @($c.roles | Where-Object assignable).Count
  Write-Host ("{0,-7} {1} roles ({2} assignable)" -f $c.module, @($c.roles).Count, $assignable)
}

$h = @{ Authorization = "Bearer $(Get-IdToken 'hr-spa' 'admin' 'adminadmin')" }
$agg = Invoke-RestMethod "$hr/api/access-catalog" -Headers $h
foreach ($m in $agg.modules) { Write-Host "HR sees: $($m.module) status=$($m.status) $($m.error)" }

$stash = $agg.modules | Where-Object module -eq 'stash'
$role = $stash.roles | Where-Object { $_.key -eq 'conops_lead' }
$stamp = Get-Date -Format 'HHmmss'
$person = Invoke-RestMethod -Method Post -Uri "$hr/api/people" -Headers $h -ContentType 'application/json' -Body (@{
  first_name = 'Picker'; last_name = "$stamp"; nickname = "picker$stamp"; date_of_birth = '1992-03-04'
  email = "picker$stamp@conservices.local"; phone = '+43 660 1111111'; address = '2 Example Street, Vienna'
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

$bob = @{ Authorization = "Bearer $(Get-IdToken 'den-spa' 'bob' 'bobbob')" }
try { Invoke-RestMethod 'http://localhost:8090/api/v1/modules' -Headers $bob | Out-Null; throw 'bob should be forbidden' }
catch { if ($_.Exception.Response.StatusCode.value__ -eq 403) { Write-Host 'Den admin API as member: 403 OK' } else { throw } }
$dash = Invoke-RestMethod 'http://localhost:8090/api/v1/dashboard' -Headers $bob
Write-Host "Den dashboard as member includes brand: $([bool]$dash.brand) primary=$($dash.brand.theme.primary)"
