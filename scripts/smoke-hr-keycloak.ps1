# Smoke: HR onboarding wizard against the real stack.
# department (Keycloak group auto-created) -> onboarding details -> access ->
# complete (Keycloak user + groups + set-password email in Mailpit).
$ErrorActionPreference = 'Stop'
$kcBase = 'http://localhost:8085'
$kc = "$kcBase/realms/conservices/protocol/openid-connect/token"
$hr = 'http://localhost:8110'
$mailpit = 'http://localhost:8025'

function Get-AccessToken($client, $user, $pass) {
  $body = @{ grant_type = 'password'; client_id = $client; username = $user; password = $pass; scope = 'openid profile email' }
  # HR accepts the access token (audience hr-api) and refuses the ID token.
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).access_token
}
function Post-Json($uri, $body, $method = 'Post') {
  Invoke-RestMethod -Method $method -Uri $uri -Headers $h -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 6)
}

$tok = Get-AccessToken 'hr-spa' 'admin' 'adminadmin'
$h = @{ Authorization = "Bearer $tok" }
$me = Invoke-RestMethod -Uri "$hr/api/me" -Headers $h
Write-Host "HR /me: $($me.username) mode=$($me.auth_mode)"

# Pick a real assignable Stash role from the live catalog.
$catalog = Invoke-RestMethod -Uri "$hr/api/access-catalog" -Headers $h
$stash = $catalog.modules | Where-Object { $_.module -eq 'stash' }
$assignable = @($stash.roles | Where-Object { $_.assignable -and $_.group })
$role = ($assignable | Where-Object { $_.key -match 'volunteer' } | Select-Object -First 1)
if (-not $role) { $role = $assignable | Where-Object { $_.key -notmatch 'admin' } | Select-Object -First 1 }
if (-not $role) { throw 'no assignable stash role in catalog' }
$roleRef = @{ role_name = "stash:$($role.key)"; group_name = $role.group; scope = $role.scope }
Write-Host "Default role for department: stash:$($role.key) -> $($role.group)"

$stamp = Get-Date -Format 'HHmmss'
$existing = (Invoke-RestMethod -Uri "$hr/api/departments" -Headers $h).items | Where-Object { $_.slug -eq 'smoke-ops' }
if ($existing) {
  $dept = Post-Json "$hr/api/departments/$($existing.id)" @{ name = 'Smoke Ops'; description = 'Used by scripts/smoke-hr-keycloak.ps1'; default_roles = @($roleRef) } 'Put'
} else {
  $dept = Post-Json "$hr/api/departments" @{ name = 'Smoke Ops'; slug = 'smoke-ops'; description = 'Used by scripts/smoke-hr-keycloak.ps1'; default_roles = @($roleRef) }
}
if ($dept.idp_sync_error) { throw "department group sync failed: $($dept.idp_sync_error)" }
Write-Host "Department: $($dept.name) group=$($dept.group_name) synced=$($dept.idp_synced_at)"

$email = "crew$stamp@conservices.local"
$person = @{
  first_name = 'Crew'; last_name = "Member$stamp"; nickname = "Smoke Paws $stamp"; date_of_birth = '1995-06-15'
  email = $email; phone = '+43 660 1234567'; address = '1 Example Street, Vienna'
  social_handles = @{ telegram = "@crew$stamp" }
  emergency_contact = @{ name = 'Parent Person'; phone = '+43 660 7654321' }
}
try {
  Post-Json "$hr/api/onboardings" @{ department_id = $dept.id; person = @{ first_name = 'X'; last_name = 'Y'; email = "x$stamp@conservices.local" } } | Out-Null
  throw 'incomplete profile was accepted'
} catch { if ($_.Exception.Message -eq 'incomplete profile was accepted') { throw } ; Write-Host 'Incomplete profile rejected: OK' }

$view = Post-Json "$hr/api/onboardings" @{ department_id = $dept.id; person = $person }
Write-Host "Onboarding started: draft=$($view.draft.id) prefilled roles=$(($view.draft.roles | ForEach-Object role_name) -join ',')"
Post-Json "$hr/api/drafts/$($view.draft.id)/roles" @{ roles = @($roleRef) } 'Put' | Out-Null

$queued = Invoke-RestMethod -Method Post -Uri "$hr/api/onboardings/$($view.draft.id)/complete" -Headers $h
$res = $queued
if ($queued.queued) {
  # Completion runs as a background job (JOB_INTERVAL); wait for it.
  $deadline = (Get-Date).AddSeconds(90)
  do {
    Start-Sleep -Seconds 2
    $job = Invoke-RestMethod -Uri "$hr/api/jobs/$($queued.job_id)" -Headers $h
  } while ($job.status -notin 'succeeded', 'failed' -and (Get-Date) -lt $deadline)
  if ($job.status -ne 'succeeded') { throw "complete job $($job.status): $($job.last_error)" }
  $res = $job.result
  if (-not $res.draft) { $res | Add-Member -NotePropertyName draft -NotePropertyValue $queued.draft }
}
if (-not $res.ok) { throw "complete failed: $($res.error)" }
Write-Host "Complete: draft=$($res.draft.state) created=$($res.account_created) groups=$($res.groups_applied -join ',') email_sent=$($res.password_setup_email_sent) $($res.password_setup_error)"
if (-not $res.password_setup_email_sent) { throw 'set-password email was not sent' }

# Keycloak: user exists with department + role groups.
$adminTok = (Invoke-RestMethod -Method Post -Uri "$kcBase/realms/master/protocol/openid-connect/token" -Body @{
  grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = 'admin' }).access_token
$ah = @{ Authorization = "Bearer $adminTok" }
$kcUser = (Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users?email=$email&exact=true" -Headers $ah)[0]
$kcGroups = (Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users/$($kcUser.id)/groups" -Headers $ah) | ForEach-Object name
Write-Host "Keycloak user: $($kcUser.username) ($($kcUser.firstName) $($kcUser.lastName)) groups=$($kcGroups -join ',')"
foreach ($g in @($dept.group_name, $role.group)) { if ($kcGroups -notcontains $g) { throw "missing group $g" } }

# New accounts: login name from the username template, HR fields as attributes.
$settings = Invoke-RestMethod -Uri "$hr/api/settings" -Headers $h
if ($settings.username_template -eq '{nickname}' -and $kcUser.username -ne "smoke-paws-$stamp") {
  throw "username $($kcUser.username) does not follow {nickname}"
}
$kcFull = Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users/$($kcUser.id)" -Headers $ah
# KEYCLOAK_USER_ATTRIBUTES default: hrPersonId,nickname,orgEmail (orgEmail only when set).
foreach ($a in 'nickname', 'hrPersonId') {
  if (-not $kcFull.attributes.$a) { throw "Keycloak attribute $a missing" }
}
if ($kcFull.attributes.nickname[0] -ne $person.nickname) { throw 'Keycloak attributes do not match HR' }
Write-Host "Keycloak login name $($kcUser.username), attributes nickname/hrPersonId: OK"

# Mailpit: onboarding email with a set-password link.
Start-Sleep -Seconds 2
$msgs = Invoke-RestMethod -Uri "$mailpit/api/v1/search?query=to:$email"
$msg = $msgs.messages | Select-Object -First 1
if (-not $msg) { throw "no email for $email in Mailpit" }
$full = Invoke-RestMethod -Uri "$mailpit/api/v1/message/$($msg.ID)"
if ($full.Text -notmatch 'login-actions/action-token') { throw 'email has no set-password link' }
Write-Host "Mail: '$($msg.Subject)' to $email with set-password link: OK"
Write-Host "Open $mailpit to see it."

# HR Keycloak view: the department group lists the new user.
$idp = Invoke-RestMethod -Uri "$hr/api/idp/groups" -Headers $h
$deptGroup = $idp.groups | Where-Object { $_.name -eq $dept.group_name }
if (-not ($deptGroup.members | Where-Object { $_.id -eq $kcUser.id })) { throw 'HR Keycloak view does not show the user in the department group' }
Write-Host "HR Keycloak view: $($idp.groups.Count) groups, $($dept.group_name) has the user: OK"

# Profile edit syncs to Keycloak.
$pid_ = $res.draft.person_id
$p = Invoke-RestMethod -Uri "$hr/api/people/$pid_" -Headers $h
$edit = @{
  first_name = $p.first_name; last_name = "$($p.last_name)Edited"; nickname = "$($p.nickname) Edited"; date_of_birth = $p.date_of_birth
  email = $p.email; phone = '+43 660 9999999'; address = $p.address; social_handles = $p.social_handles; emergency_contact = $p.emergency_contact
}
$edited = Post-Json "$hr/api/people/$pid_" $edit 'Put'
if ($edited.idp_sync_error) { throw "profile sync failed: $($edited.idp_sync_error)" }
$kcEdited = Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users/$($kcUser.id)" -Headers $ah
if ($kcEdited.lastName -ne $edit.last_name) { throw "Keycloak lastName not synced: $($kcEdited.lastName)" }
if ($kcEdited.attributes.nickname[0] -ne $edit.nickname) { throw 'Keycloak attributes not synced' }
if ($kcEdited.username -ne $kcUser.username) { throw 'username changed on profile edit' }
Write-Host "Profile edit synced to Keycloak (lastName, nickname; username unchanged): OK"

# Offboard: Keycloak account deleted, notice emailed, HR record deleted.
$off = Post-Json "$hr/api/people/$pid_/offboard" @{ reason = 'smoke test'; share_reason = $true }
if ($off.warnings) { throw "offboard warnings: $($off.warnings -join '; ')" }
try {
  Invoke-RestMethod -Uri "$kcBase/admin/realms/conservices/users/$($kcUser.id)" -Headers $ah | Out-Null
  throw 'Keycloak user still exists after offboard'
} catch { if ($_.Exception.Message -eq 'Keycloak user still exists after offboard') { throw } }
Start-Sleep -Seconds 2
$notice = (Invoke-RestMethod -Uri "$mailpit/api/v1/search?query=to:$email subject:deleted").messages | Select-Object -First 1
if (-not $notice) { throw "no account-deleted email for $email" }
$noticeText = (Invoke-RestMethod -Uri "$mailpit/api/v1/message/$($notice.ID)").Text
if ($noticeText -notmatch 'Reason: smoke test') { throw 'deleted notice is missing the shared reason' }
$gone = $false
try { Invoke-RestMethod -Uri "$hr/api/people/$pid_" -Headers $h | Out-Null }
catch { $gone = $_.Exception.Response.StatusCode.value__ -eq 404 }
if (-not $gone) { throw 'HR still has the person after offboard (want 404)' }
Write-Host "Offboard: Keycloak user deleted, '$($notice.Subject)' emailed, HR record deleted (404): OK"
