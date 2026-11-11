# Smoke: Learn course loop against the real stack.
# A throwaway trainer (group learn-trainer) builds and publishes a course ->
# a throwaway learner (no Learn group) self-enrols, reads the page, marks it
# done -> progress updates; plus the negative checks (draft hidden, learner
# cannot edit, trainer cannot make trainers). Then media (upload, content
# check, attachment), a quiz (fail, pass, reset rules), an in-person session
# (booking, QR check-in) and the certificate it all earns (verify, survives a
# quiz reset, revoke). The Keycloak users are created for the run and deleted
# at the end; the smoke course stays behind archived, and its qualification
# (smoke-<time>, revoked certificate) stays too, like the HR smoke leaves its
# test people. Media is skipped when the stack has no object storage.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/smoke-lib.ps1"
$kcBase = Get-SmokeUrl 'KEYCLOAK' 'http://localhost:8085'
$kc = "$kcBase/realms/conservices/protocol/openid-connect/token"
$learn = Get-SmokeUrl 'LEARN_API' 'http://localhost:8120'

function Get-AccessToken($user, $pass) {
  # The API accepts access tokens (audience learn-api) and refuses ID tokens.
  $body = @{ grant_type = 'password'; client_id = 'learn-spa'; username = $user; password = $pass; scope = 'openid profile email' }
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).access_token
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

$trainer = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-trainer' 'smoke-trainer-pass')" }
$learner = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-learner' 'smoke-learner-pass')" }
$admin = @{ Authorization = "Bearer $(Get-AccessToken 'admin' 'adminadmin')" }

# Permissions come through the groups -> access-config bindings.
$me = Call $trainer 'Get' '/api/v1/me'
Write-Host "trainer /me: $($me.display_name) perms=$($me.permissions -join ',')"
if ($me.permissions -notcontains 'course.teach') { throw 'smoke-trainer is missing course.teach (learn-trainer group not mapped?)' }

# Role catalog (HR's service token, or a staff sign-in).
$catalog = Call $trainer 'Get' '/api/role-catalog' $null
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

# Only a training manager (staff.manage) makes someone a trainer.
$learnerEnr = $enr.enrolments | Where-Object { $_.role -eq 'learner' } | Select-Object -First 1
Expect-Status 403 $trainer 'Post' "/api/v1/courses/$($course.id)/enrolments" @{ user_id = $learnerEnr.user_id; role = 'trainer' } 'trainer makes a trainer'
$trainerEnr = $enr.enrolments | Where-Object { $_.role -eq 'trainer' } | Select-Object -First 1
Expect-Status 409 $admin 'Delete' "/api/v1/enrolments/$($trainerEnr.id)" $null 'removing the last trainer'

# ---------------------------------------------------------------------------
# Media: a real PNG becomes ready; a text file announced as PNG is rejected
# and removed. The browser uploads straight to storage with the presigned
# form; curl.exe does the same here. -k: local dev stack only (Caddy's
# internal CA may not be trusted by curl.exe).
# ---------------------------------------------------------------------------
function Send-ToStorage($ticket, $path, $contentType) {
  $form = @()
  foreach ($f in $ticket.fields.PSObject.Properties) { $form += @('--form-string', "$($f.Name)=$($f.Value)") }
  $form += @('-F', "file=@$path;type=$contentType")
  $code = & curl.exe -s -k -o NUL -w '%{http_code}' @form $ticket.url
  if ($code -notmatch '^2') { throw "upload to storage answered $code" }
}
function Start-Upload($name, $path, $contentType, $alt) {
  Call $trainer 'Post' "/api/v1/courses/$($course.id)/media/uploads" @{
    filename = $name; content_type = $contentType; size_bytes = (Get-Item $path).Length; alt_text = $alt }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) "learn-smoke-$stamp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$pngPath = Join-Path $tmp 'dot.png'
[IO.File]::WriteAllBytes($pngPath, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
$fakePath = Join-Path $tmp 'fake.png'
[IO.File]::WriteAllText($fakePath, 'this is not a picture at all, just text')

$mediaOn = $true
try { $ticket = Start-Upload 'dot.png' $pngPath 'image/png' 'A single dot' }
catch {
  if ([int]$_.Exception.Response.StatusCode -ne 503) { throw }
  $mediaOn = $false
  Write-Host 'media: object storage off (503), skipping the media checks'
}
if ($mediaOn) {
  Send-ToStorage $ticket $pngPath 'image/png'
  $m = Call $trainer 'Post' "/api/v1/media/$($ticket.media.id)/complete" $null
  if ($m.status -ne 'ready') { throw "real PNG is $($m.status) after complete, expected ready" }
  Write-Host "media: $($m.id) ready"

  $bad = Start-Upload 'fake.png' $fakePath 'image/png' 'Not a picture'
  Send-ToStorage $bad $fakePath 'image/png'
  Expect-Status 422 $trainer 'Post' "/api/v1/media/$($bad.media.id)/complete" $null 'completing a text file announced as PNG'
  Expect-Status 404 $trainer 'Get' "/api/v1/media/$($bad.media.id)/url" $null 'rejected upload is gone'

  Call $trainer 'Post' "/api/v1/activities/$($page.id)/media" @{ media_id = $m.id; caption = 'Smoke picture' } | Out-Null
  $att = Call $learner 'Get' "/api/v1/activities/$($page.id)/media"
  if (@($att.attachments).Count -ne 1) { throw "learner sees $(@($att.attachments).Count) attachments, expected 1" }
  $view = Call $learner 'Get' "/api/v1/media/$($m.id)/url"
  if (-not $view.url) { throw 'learner got no view URL for the attached picture' }
  Write-Host 'media: attached and visible to the learner'
}
Remove-Item -Recurse -Force $tmp

# ---------------------------------------------------------------------------
# Qualification: the course awards it once every activity is done.
# ---------------------------------------------------------------------------
$qual = Call $admin 'Post' '/api/v1/qualifications' @{ key = "smoke-$stamp"; name = "Smoke qualification $stamp"; valid_months = 12 }
Call $trainer 'Put' "/api/v1/courses/$($course.id)/qualification" @{ qualification_id = $qual.id } | Out-Null
Expect-Status 403 $trainer 'Post' '/api/v1/qualifications' @{ key = "smoke-t-$stamp"; name = 'Trainer qualification' } 'trainer creates a qualification'
Write-Host "qualification: $($qual.key)"

# ---------------------------------------------------------------------------
# Quiz: one question; a wrong attempt fails, a right one passes.
# ---------------------------------------------------------------------------
$section2 = Call $trainer 'Post' "/api/v1/courses/$($course.id)/sections" @{ title = 'Practice' }
$cat = Call $trainer 'Post' "/api/v1/courses/$($course.id)/question-categories" @{ name = 'Smoke' }
$q = Call $trainer 'Post' "/api/v1/question-categories/$($cat.id)/questions" @{
  kind = 'single'; prompt = 'Which channel is for emergencies?'; points = 1
  options = @(@{ label = 'Channel 1'; correct = $true }, @{ label = 'Channel 5'; correct = $false })
}
$right = ($q.options | Where-Object { $_.correct }).id
$wrong = ($q.options | Where-Object { -not $_.correct }).id
$quiz = Call $trainer 'Post' "/api/v1/sections/$($section2.id)/activities" @{ kind = 'quiz'; title = "Smoke quiz $stamp"; pass_percent = 100; max_attempts = 3 }
Call $trainer 'Post' "/api/v1/activities/$($quiz.id)/slots" @{ question_id = $q.id } | Out-Null

$att1 = Call $learner 'Post' "/api/v1/activities/$($quiz.id)/attempts" $null
$res1 = Call $learner 'Post' "/api/v1/attempts/$($att1.id)/submit" @{ answers = @{ "$($q.id)" = @($wrong) } }
if ($res1.passed) { throw 'wrong answer passed the quiz' }
Expect-Status 409 $learner 'Post' "/api/v1/attempts/$($att1.id)/submit" @{ answers = @{ "$($q.id)" = @($right) } } 'resubmitting an attempt'
$att2 = Call $learner 'Post' "/api/v1/activities/$($quiz.id)/attempts" $null
$res2 = Call $learner 'Post' "/api/v1/attempts/$($att2.id)/submit" @{ answers = @{ "$($q.id)" = @($right) } }
if (-not $res2.passed -or $res2.percent -ne 100) { throw "right answer gave $($res2.percent)% passed=$($res2.passed)" }
Write-Host "quiz: failed at $($res1.percent)%, passed at $($res2.percent)%"
$gb = Call $trainer 'Get' "/api/v1/courses/$($course.id)/gradebook"
$cell = ($gb.rows | Where-Object { $_.user_id -eq $learnerEnr.user_id }).cells | Where-Object { $_.activity_id -eq $quiz.id }
if (-not $cell.passed -or $cell.attempts -ne 2) { throw "gradebook shows attempts=$($cell.attempts) passed=$($cell.passed)" }

# ---------------------------------------------------------------------------
# In-person session: book a slot, check in with the rotating QR code.
# Check-in opens 30 minutes before the start, so a slot in 10 minutes works.
# ---------------------------------------------------------------------------
$session = Call $trainer 'Post' "/api/v1/sections/$($section2.id)/activities" @{ kind = 'session'; title = 'Smoke practical' }
$now = (Get-Date).ToUniversalTime()
$slot = Call $trainer 'Post' "/api/v1/activities/$($session.id)/session-slots" @{
  starts_at = $now.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ')
  ends_at   = $now.AddMinutes(70).ToString('yyyy-MM-ddTHH:mm:ssZ')
  location  = 'Smoke hall'; capacity = 5
}
$booking = Call $learner 'Post' "/api/v1/slots/$($slot.id)/booking" $null
if ($booking.status -ne 'booked') { throw "booking status is $($booking.status), expected booked" }
Expect-Status 403 $learner 'Get' "/api/v1/slots/$($slot.id)/checkin-code" $null 'learner reads the check-in code'
$code = Call $trainer 'Get' "/api/v1/slots/$($slot.id)/checkin-code"
Expect-Status 400 $learner 'Post' "/api/v1/slots/$($slot.id)/checkin" @{ code = 'WRONG000' } 'check-in with a wrong code'
$ci = Call $learner 'Post' "/api/v1/slots/$($slot.id)/checkin" @{ code = $code.code }
if ($ci.signup.status -ne 'attended') { throw "check-in left the signup $($ci.signup.status)" }
$roster = Call $trainer 'Get' "/api/v1/slots/$($slot.id)/roster"
Write-Host "session: checked in; roster has $(@($roster.signups).Count) signup(s)"

# ---------------------------------------------------------------------------
# Certificate: issued now that page, quiz and session are done.
# ---------------------------------------------------------------------------
$mine = Call $learner 'Get' '/api/v1/me/qualifications'
$cert = $mine.qualifications | Where-Object { $_.qualification_key -eq $qual.key } | Select-Object -First 1
if (-not $cert) { throw 'no certificate after finishing every activity' }
if ($cert.status -ne 'valid') { throw "certificate status is $($cert.status), expected valid" }
$verify = Invoke-RestMethod -Uri "$learn/api/public/verify/$($cert.verify_code)"
if ($verify.status -ne 'valid') { throw "public verify says $($verify.status), expected valid" }
Write-Host "certificate: $($cert.verify_code) valid"

# Quiz reset: course.manage only, typed title, current cycle only; the
# certificate already issued stays valid.
Expect-Status 403 $trainer 'Post' "/api/v1/activities/$($quiz.id)/reset" @{ confirm = $quiz.title } 'trainer resets the quiz'
Expect-Status 422 $admin 'Post' "/api/v1/activities/$($quiz.id)/reset" @{ confirm = 'not the title' } 'reset with the wrong title'
$reset = Call $admin 'Post' "/api/v1/activities/$($quiz.id)/reset" @{ confirm = $quiz.title }
if ($reset.attempts -lt 2) { throw "reset removed $($reset.attempts) attempts, expected at least 2" }
$verify = Invoke-RestMethod -Uri "$learn/api/public/verify/$($cert.verify_code)"
if ($verify.status -ne 'valid') { throw "certificate is $($verify.status) after a quiz reset, expected valid" }
Write-Host "quiz reset: $($reset.attempts) attempts removed, certificate still valid"

# Revoke (training office); verify follows.
Expect-Status 403 $trainer 'Post' "/api/v1/certificates/$($cert.id)/revoke" @{ reason = 'smoke' } 'trainer revokes a certificate'
Call $admin 'Post' "/api/v1/certificates/$($cert.id)/revoke" @{ reason = 'Smoke test' } | Out-Null
$verify = Invoke-RestMethod -Uri "$learn/api/public/verify/$($cert.verify_code)"
if ($verify.status -ne 'revoked') { throw "public verify says $($verify.status) after revoke" }
Write-Host 'certificate: revoked'

# Park the smoke course: unpublished and archived (hidden, read-only,
# reversible), then delete the throwaway Keycloak users.
Call $admin 'Post' "/api/v1/courses/$($course.id)/unpublish" $null | Out-Null
Call $admin 'Post' "/api/v1/courses/$($course.id)/archive" $null | Out-Null
Expect-Status 409 $trainer 'Patch' "/api/v1/courses/$($course.id)" @{ title = 'edit archived' } 'trainer edits archived course'
Remove-SmokeUser $trainerUid
Remove-SmokeUser $learnerUid

Write-Host 'learn smoke: OK'
