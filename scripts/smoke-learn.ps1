# Smoke: Learn course loop against the real stack.
# A throwaway trainer (group learn-trainer) builds and publishes a course ->
# a throwaway learner (no Learn group) self-enrols, reads the page, marks it
# done -> progress updates; plus the negative checks (draft hidden, learner
# cannot edit). The Keycloak users are created for the run and deleted at the
# end; the smoke course stays behind (unpublished), like the HR smoke leaves
# its test people.
$ErrorActionPreference = 'Stop'
$kcBase = 'http://localhost:8085'
$kc = "$kcBase/realms/conservices/protocol/openid-connect/token"
$learn = 'http://localhost:8120'

function Get-IdToken($user, $pass) {
  $body = @{ grant_type = 'password'; client_id = 'learn-spa'; username = $user; password = $pass; scope = 'openid profile email' }
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).id_token
}

# Throwaway users via the Keycloak admin API (the dev realm drifts: the
# seeded alice/bob may have been offboarded by HR runs).
$adminTok = (Invoke-RestMethod -Method Post -Uri "$kcBase/realms/master/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = 'admin' }).access_token
$ah = @{ Authorization = "Bearer $adminTok" }

function Ensure-SmokeUser($username, $pass, $group) {
  $existing = Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users?username=$username&exact=true" -Headers $ah
  if ($existing) { Invoke-RestMethod -Method Delete -Uri "$kcBase/admin/realms/conservices/users/$($existing[0].id)" -Headers $ah }
  $body = @{
    username = $username; enabled = $true; emailVerified = $true
    firstName = 'Smoke'; lastName = $username; email = "$username@conservices.local"
    credentials = @(@{ type = 'password'; value = $pass; temporary = $false })
  } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method Post -Uri "$kcBase/admin/realms/conservices/users" -Headers $ah -ContentType 'application/json' -Body $body | Out-Null
  $uid = (Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users?username=$username&exact=true" -Headers $ah)[0].id
  if ($group) {
    $gid = (Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/groups?search=$group" -Headers $ah |
      Where-Object { $_.name -eq $group } | Select-Object -First 1).id
    if (-not $gid) { throw "Keycloak group $group not found (run infra/keycloak/apply-mvp.sh)" }
    Invoke-RestMethod -Method Put -Uri "$kcBase/admin/realms/conservices/users/$uid/groups/$gid" -Headers $ah | Out-Null
  }
  return $uid
}
function Remove-SmokeUser($uid) {
  try { Invoke-RestMethod -Method Delete -Uri "$kcBase/admin/realms/conservices/users/$uid" -Headers $ah | Out-Null } catch {}
}

$trainerUid = Ensure-SmokeUser 'smoke-trainer' 'smoke-trainer-pass' 'learn-trainer'
$learnerUid = Ensure-SmokeUser 'smoke-learner' 'smoke-learner-pass' $null
function Call($headers, $method, $path, $body) {
  if ($null -ne $body) {
    Invoke-RestMethod -Method $method -Uri "$learn$path" -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 6)
  } else {
    Invoke-RestMethod -Method $method -Uri "$learn$path" -Headers $headers
  }
}
function Expect-Status($expected, $headers, $method, $path, $body, $what) {
  try {
    Call $headers $method $path $body | Out-Null
    throw "EXPECTED-FAIL"
  } catch {
    if ($_.Exception.Message -eq 'EXPECTED-FAIL') { throw "$what succeeded but should have returned $expected" }
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -ne $expected) { throw "$what returned $status, expected $expected" }
    Write-Host "${what}: $status as expected"
  }
}

$trainer = @{ Authorization = "Bearer $(Get-IdToken 'smoke-trainer' 'smoke-trainer-pass')" }
$learner = @{ Authorization = "Bearer $(Get-IdToken 'smoke-learner' 'smoke-learner-pass')" }
$admin = @{ Authorization = "Bearer $(Get-IdToken 'admin' 'adminadmin')" }

# Permissions come through the groups -> access-config bindings.
$me = Call $trainer 'Get' '/api/v1/me'
Write-Host "trainer /me: $($me.display_name) perms=$($me.permissions -join ',')"
if ($me.permissions -notcontains 'course.teach') { throw 'smoke-trainer is missing course.teach (learn-trainer group not mapped?)' }

# Public role catalog (what HR aggregates).
$catalog = Invoke-RestMethod -Uri "$learn/api/role-catalog"
if ($catalog.module -ne 'learn') { throw 'role catalog module mismatch' }
Write-Host "role catalog: $(($catalog.roles | ForEach-Object key) -join ',')"

# Trainer builds a course.
$stamp = Get-Date -Format 'HHmmss'
$course = Call $trainer 'Post' '/api/v1/courses' @{ title = "Smoke course $stamp"; summary = 'Created by scripts/smoke-learn.ps1' }
$section = Call $trainer 'Post' "/api/v1/courses/$($course.id)/sections" @{ title = 'Only section' }
$page = Call $trainer 'Post' "/api/v1/sections/$($section.id)/activities" @{ title = 'Only page'; body = 'Read me, mark me done.' }
Write-Host "course: $($course.id) section=$($section.id) page=$($page.id)"

# Draft invisible to the learner (404, not 403 — existence stays hidden).
Expect-Status 404 $learner 'Get' "/api/v1/courses/$($course.id)" $null 'learner reads draft'

# Publish + open self-enrolment.
Call $trainer 'Post' "/api/v1/courses/$($course.id)/publish" $null | Out-Null
Call $trainer 'Patch' "/api/v1/courses/$($course.id)" @{ self_enrol = $true } | Out-Null

# Published but not enrolled: still closed.
Expect-Status 403 $learner 'Get' "/api/v1/courses/$($course.id)" $null 'learner reads published course without enrolment'

# The learner finds it in the catalog and self-enrols.
$cat = Call $learner 'Get' '/api/v1/courses/catalog'
if (-not ($cat.courses | Where-Object { $_.id -eq $course.id })) { throw 'course missing from catalog' }
Call $learner 'Post' "/api/v1/courses/$($course.id)/enrol" $null | Out-Null
$detail = Call $learner 'Get' "/api/v1/courses/$($course.id)"
if ($detail.progress.total -ne 1 -or $detail.progress.completed -ne 0) { throw "fresh progress is $($detail.progress.completed)/$($detail.progress.total), expected 0/1" }

# Learner cannot edit.
Expect-Status 403 $learner 'Patch' "/api/v1/courses/$($course.id)" @{ title = 'hijack' } 'learner edits course'

# Completion moves progress.
Call $learner 'Put' "/api/v1/activities/$($page.id)/completion" @{ completed = $true } | Out-Null
$detail = Call $learner 'Get' "/api/v1/courses/$($course.id)"
if ($detail.progress.completed -ne 1) { throw 'completion did not move progress' }
Write-Host "learner progress: $($detail.progress.completed)/$($detail.progress.total)"

# Admin sees the enrolments (the trainer + the learner).
$enr = Call $admin 'Get' "/api/v1/courses/$($course.id)/enrolments"
$roles = ($enr.enrolments | ForEach-Object role | Sort-Object) -join ','
if ($roles -ne 'learner,trainer') { throw "enrolments are [$roles], expected learner+trainer" }
Write-Host "enrolments: $(($enr.enrolments | ForEach-Object { "$($_.display_name)($($_.role))" }) -join ', ')"

# Park the smoke course as an unpublished draft so it stays out of catalogs,
# and delete the throwaway Keycloak users.
Call $admin 'Post' "/api/v1/courses/$($course.id)/unpublish" $null | Out-Null
Remove-SmokeUser $trainerUid
Remove-SmokeUser $learnerUid

Write-Host 'learn smoke: OK'
