# Smoke: Stash inventory, sign-outs, Lost & Found, files and privacy.
# An admin creates a department and an item, generates its code, signs 3
# units out and takes them back (one damaged); a read-only user cannot
# create items and sees guest data in the audit log redacted. Also checks
# the role catalog, settings validation, the reduced public Lost & Found
# view, CSV formula escaping, safe file downloads and the audit page cap.
#
# Against the Docker Compose stack (Keycloak sign-in; two throwaway
# Keycloak users are created and deleted again):
#   ./scripts/smoke-stash.ps1
# Against a backend started with AUTH_MODE=dev (X-Dev-User sign-in):
#   ./scripts/smoke-stash.ps1 -BaseUrl http://localhost:18080 -Auth dev
# The item is retired and the report removed at the end; the department
# and the audit entries stay (the audit log is append-only).
param(
  [string]$BaseUrl = 'http://localhost:8088',
  [ValidateSet('oidc', 'dev')][string]$Auth = 'oidc',
  [string]$KeycloakUrl = 'http://localhost:8085'
)
$ErrorActionPreference = 'Stop'
$stash = $BaseUrl.TrimEnd('/')
$kc = "$KeycloakUrl/realms/conservices/protocol/openid-connect/token"

function Get-IdToken($user, $pass) {
  $body = @{ grant_type = 'password'; client_id = 'stash-spa'; username = $user; password = $pass; scope = 'openid profile email' }
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).id_token
}

# Keycloak admin (dev stack only; the dev default is admin/admin).
$ah = $null
function Connect-KeycloakAdmin {
  $pw = if ($env:KEYCLOAK_ADMIN_PASSWORD) { $env:KEYCLOAK_ADMIN_PASSWORD } else { 'admin' }
  $tok = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
      grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = $pw }).access_token
  $script:ah = @{ Authorization = "Bearer $tok" }
}
function Ensure-SmokeUser($username, $pass, $group) {
  $existing = Invoke-RestMethod -Uri "$KeycloakUrl/admin/realms/conservices/users?username=$username&exact=true" -Headers $ah
  if ($existing) { Invoke-RestMethod -Method Delete -Uri "$KeycloakUrl/admin/realms/conservices/users/$($existing[0].id)" -Headers $ah }
  $body = @{
    username = $username; enabled = $true; emailVerified = $true
    firstName = 'Smoke'; lastName = $username; email = "$username@conservices.local"
    credentials = @(@{ type = 'password'; value = $pass; temporary = $false })
  } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/admin/realms/conservices/users" -Headers $ah -ContentType 'application/json' -Body $body | Out-Null
  $uid = (Invoke-RestMethod -Uri "$KeycloakUrl/admin/realms/conservices/users?username=$username&exact=true" -Headers $ah)[0].id
  $gid = (Invoke-RestMethod -Uri "$KeycloakUrl/admin/realms/conservices/groups?search=$group" -Headers $ah |
    Where-Object { $_.name -eq $group } | Select-Object -First 1).id
  if (-not $gid) { throw "Keycloak group $group not found (run infra/keycloak/apply-mvp.sh)" }
  Invoke-RestMethod -Method Put -Uri "$KeycloakUrl/admin/realms/conservices/users/$uid/groups/$gid" -Headers $ah | Out-Null
  return $uid
}
function Remove-SmokeUser($uid) {
  if (-not $uid) { return }
  try { Invoke-RestMethod -Method Delete -Uri "$KeycloakUrl/admin/realms/conservices/users/$uid" -Headers $ah | Out-Null } catch {}
}

function Call($headers, $method, $path, $body) {
  if ($null -ne $body) {
    Invoke-RestMethod -Method $method -Uri "$stash$path" -Headers $headers -ContentType 'application/json; charset=utf-8' `
      -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6)))
  } else {
    Invoke-RestMethod -Method $method -Uri "$stash$path" -Headers $headers
  }
}
function Expect-Status($expected, $headers, $method, $path, $body, $what) {
  try {
    Call $headers $method $path $body | Out-Null
    throw 'EXPECTED-FAIL'
  } catch {
    if ($_.Exception.Message -eq 'EXPECTED-FAIL') { throw "$what succeeded but should have returned $expected" }
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -ne $expected) { throw "$what returned $status, expected $expected" }
    Write-Host "${what}: $status as expected"
  }
}
function Get-Raw($headers, $path) {
  Invoke-WebRequest -UseBasicParsing -Uri "$stash$path" -Headers $headers
}
function Upload-File($headers, $entityType, $entityId, $fileType, $name, $contentType, [byte[]]$bytes) {
  Add-Type -AssemblyName System.Net.Http
  $client = New-Object System.Net.Http.HttpClient
  try {
    foreach ($k in $headers.Keys) { $client.DefaultRequestHeaders.TryAddWithoutValidation($k, $headers[$k]) | Out-Null }
    $mp = New-Object System.Net.Http.MultipartFormDataContent
    $fc = New-Object System.Net.Http.ByteArrayContent(, $bytes)
    $fc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($contentType)
    $mp.Add($fc, 'file', $name)
    $mp.Add((New-Object System.Net.Http.StringContent($entityType)), 'entity_type')
    $mp.Add((New-Object System.Net.Http.StringContent($entityId)), 'entity_id')
    $mp.Add((New-Object System.Net.Http.StringContent($fileType)), 'file_type')
    $res = $client.PostAsync("$stash/api/files/upload", $mp).Result
    $text = $res.Content.ReadAsStringAsync().Result
    if ([int]$res.StatusCode -ne 201) { throw "upload of $name returned $([int]$res.StatusCode): $text" }
    $text | ConvertFrom-Json
  } finally { $client.Dispose() }
}

$adminUid = $null; $roUid = $null
if ($Auth -eq 'oidc') {
  Connect-KeycloakAdmin
  $adminUid = Ensure-SmokeUser 'smoke-stash-admin' 'smoke-stash-admin-pass' 'stash-admin'
  $roUid = Ensure-SmokeUser 'smoke-stash-ro' 'smoke-stash-ro-pass' 'stash-readonly'
  $admin = @{ Authorization = "Bearer $(Get-IdToken 'smoke-stash-admin' 'smoke-stash-admin-pass')" }
  $ro = @{ Authorization = "Bearer $(Get-IdToken 'smoke-stash-ro' 'smoke-stash-ro-pass')" }
} else {
  $admin = @{ 'X-Dev-User' = 'smoke-stash-admin' }
  $ro = @{ 'X-Dev-User' = 'smoke-stash-ro:readonly' }
}

$stamp = Get-Date -Format 'HHmmss'
$item = $null; $report = $null
try {
  Invoke-RestMethod "$stash/api/health" | Out-Null

  # Role catalog: every role once, as stash_<role>.
  $catalog = Invoke-RestMethod -Uri "$stash/api/role-catalog"
  if ($catalog.module -ne 'stash') { throw 'role catalog module mismatch' }
  $keys = @($catalog.roles | ForEach-Object key)
  if ($keys | Where-Object { $_ -notlike 'stash_*' }) { throw "role keys without stash_ prefix: $($keys -join ',')" }
  foreach ($k in 'stash_admin', 'stash_volunteer', 'stash_readonly', 'stash_frontdesk') {
    if ($keys -notcontains $k) { throw "role catalog is missing $k" }
  }
  Write-Host "role catalog: $($keys -join ',')"

  $me = Call $admin 'Get' '/api/me'
  if ($me.permissions -notcontains 'item.create') { throw 'smoke admin is missing item.create (stash-admin group not mapped?)' }
  $roMe = Call $ro 'Get' '/api/me'
  if ($roMe.roles -notcontains 'stash_readonly' -or $roMe.permissions -contains 'item.create') {
    throw "read-only user has roles $($roMe.roles -join ',') and permissions $($roMe.permissions -join ',')"
  }
  Write-Host 'who am I (admin, readonly): OK'

  # Settings are validated key by key.
  Expect-Status 422 $admin 'Patch' '/api/settings' @{ default_currency = 'euro'; is_admin = $true } 'settings with an unknown key and a bad value'
  Expect-Status 403 $ro 'Patch' '/api/settings' @{ default_currency = 'EUR' } 'read-only user changes settings'

  # Reference data and an item whose name looks like a spreadsheet formula.
  $dept = Call $admin 'Post' '/api/departments' @{ name = "Smoke dept $stamp" }
  Expect-Status 403 $ro 'Post' '/api/items' @{ name = 'Nope'; item_type = 'consumable' } 'read-only user creates an item'
  $item = Call $admin 'Post' '/api/items' @{ name = "=1+1 smoke cable $stamp"; item_type = 'consumable'; quantity_owned = 5 }
  $code = (Call $admin 'Post' "/api/items/$($item.id)/assign-barcode" $null).code
  $byCode = Call $admin 'Get' "/api/items/by-barcode/$([Uri]::EscapeDataString($code))"
  if ($byCode.id -ne $item.id) { throw "barcode $code finds item $($byCode.id), expected $($item.id)" }
  Write-Host "item $($item.id) with code ${code}: OK"

  # Sign-out lifecycle: sign out 3 of 5, too many is refused, return 2 + 1 damaged, close.
  $so = Call $admin 'Post' '/api/signouts' @{
    to_department_id = $dept.id; purpose = 'smoke'; received_by_name = 'Smoke runner'
    expected_return_at = (Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
    items = @(@{ item_id = $item.id; quantity = 3; scanned_codes = @($code) }); confirm = $true
  }
  if ($so.status -ne 'signed_out') { throw "sign-out status is $($so.status), expected signed_out" }
  $avail = Call $admin 'Get' "/api/items/$($item.id)/availability"
  if ($avail.quantity_available -ne 2) { throw "available after sign-out: $($avail.quantity_available), expected 2" }
  Expect-Status 409 $admin 'Post' '/api/signouts' @{ to_department_id = $dept.id; items = @(@{ item_id = $item.id; quantity = 3 }); confirm = $true } 'signing out more than is available'
  $line = $so.items[0].id
  $back = Call $admin 'Post' "/api/signouts/$($so.id)/return" @{ lines = @(@{ signout_item_id = $line; returned = 2; consumed = 0; lost = 0; damaged = 1; condition_on_return = 'smoke: one burnt' }) }
  if ($back.status -ne 'returned') { throw "status after return is $($back.status), expected returned" }
  $closed = Call $admin 'Post' "/api/signouts/$($so.id)/close" $null
  if ($closed.status -ne 'closed') { throw "status after close is $($closed.status)" }
  $avail = Call $admin 'Get' "/api/items/$($item.id)/availability"
  if ($avail.quantity_damaged -ne 1 -or $avail.quantity_available -ne 4) {
    throw "after return: damaged $($avail.quantity_damaged), available $($avail.quantity_available); expected 1 and 4"
  }
  $events = @((Call $admin 'Get' "/api/items/$($item.id)/history?signout_id=$($so.id)").events | ForEach-Object event_type)
  if ($events -notcontains 'signed_out' -or $events -notcontains 'returned') { throw "history events: $($events -join ',')" }
  Write-Host "sign-out $($so.signout_number) (out, refuse, return, close): OK"

  # Lost & Found: guest data is private.
  $guest = "Smoke Guest $stamp"
  $report = Call $admin 'Post' '/api/lostfound/' @{ type = 'found'; item_name = "Smoke umbrella $stamp"; description = 'secret description'; location = 'Hall Z'; contact_name = $guest; contact_info = 'guest@example.org' }
  Expect-Status 403 $ro 'Get' "/api/lostfound/$($report.id)" $null 'read-only user reads a Lost & Found report'
  try {
    $pub = Invoke-RestMethod -Uri "$stash/api/public/lostfound/?q=$([Uri]::EscapeDataString("Smoke umbrella $stamp"))"
    $hit = $pub.items | Where-Object { $_.report_number -eq $report.report_number }
    if (-not $hit) { throw 'the public search did not find the open found report' }
    $fields = @($hit.PSObject.Properties.Name | Sort-Object)
    if (($fields -join ',') -ne 'date_reported,item_name,report_number') { throw "public report shows: $($fields -join ',')" }
    Write-Host 'public Lost & Found shows only number, name and day: OK'
  } catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
      Write-Host 'public Lost & Found is off on this stack (PUBLIC_LOSTFOUND_CLAIM_ENABLED): skipped'
    } else { throw }
  }
  $roAudit = Call $ro 'Get' "/api/audit-log/?entity_type=lostfound&entity_id=$($report.id)" $null
  $adminAudit = Call $admin 'Get' "/api/audit-log/?entity_type=lostfound&entity_id=$($report.id)" $null
  if (@($roAudit.items).Count -eq 0) { throw 'no audit entry for the new report' }
  if (($roAudit | ConvertTo-Json -Depth 8) -match [regex]::Escape($guest)) { throw 'the guest name leaks into the audit log for a read-only user' }
  if (($adminAudit | ConvertTo-Json -Depth 8) -notmatch [regex]::Escape($guest)) { throw 'the admin should see the guest name in the audit log' }
  Write-Host 'audit log redacts guest data without lostfound.view: OK'
  $resolved = Call $admin 'Patch' "/api/lostfound/$($report.id)" @{ status = 'returned'; returned_to = 'Smoke owner'; resolution_note = 'smoke' }
  if ($resolved.status -ne 'returned') { throw "report status is $($resolved.status)" }

  # CSV exports escape formulas and are audited.
  $csv = (Get-Raw $admin '/api/export/items.csv').Content
  if ($csv -is [byte[]]) { $csv = [Text.Encoding]::UTF8.GetString($csv) }
  if ($csv -notmatch [regex]::Escape("'=1+1 smoke cable $stamp")) { throw 'the item name was not formula-escaped in items.csv' }
  $exportAudit = Call $admin 'Get' '/api/audit-log/?action=export.items&limit=1' $null
  if (@($exportAudit.items).Count -ne 1) { throw 'the items export was not audited' }
  Expect-Status 403 $ro 'Get' '/api/export/items.csv' $null 'read-only user exports items'
  Write-Host 'CSV export (formula escaping, audit, permission): OK'

  # Files: safe raster images inline, everything else as a download.
  $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')
  $img = Upload-File $admin 'item' $item.id 'image' 'smoke.png' 'image/png' $png
  $html = Upload-File $admin 'item' $item.id 'attachment' 'smoke.html' 'text/html' ([Text.Encoding]::UTF8.GetBytes('<script>alert(1)</script>'))
  $r = Get-Raw $admin "/api/files/$($img.id)/raw"
  if ($r.Headers['Content-Type'] -notlike 'image/png*' -or $r.Headers['X-Content-Type-Options'] -ne 'nosniff') {
    throw "image raw: $($r.Headers['Content-Type']) / $($r.Headers['X-Content-Type-Options'])"
  }
  $r = Get-Raw $admin "/api/files/$($html.id)/raw"
  if ($r.Headers['Content-Type'] -notlike 'application/octet-stream*' -or $r.Headers['Content-Disposition'] -notlike 'attachment*') {
    throw "HTML raw: $($r.Headers['Content-Type']) / $($r.Headers['Content-Disposition'])"
  }
  Expect-Status 422 $admin 'Post' '/api/files/' @{
    entity_type = 'item'; entity_id = $item.id; file_type = 'attachment'; storage_key = "stash/item/$([guid]::NewGuid())/x.pdf"
    original_filename = 'x.pdf'; content_type = 'application/pdf'; size_bytes = 1
  } 'registering another entity''s storage key'
  Call $admin 'Delete' "/api/files/$($img.id)" $null | Out-Null
  Call $admin 'Delete' "/api/files/$($html.id)" $null | Out-Null
  Write-Host 'files (inline PNG, HTML as download, foreign key refused): OK'

  # The audit page size is capped.
  $page = Call $admin 'Get' '/api/audit-log/?limit=100000&offset=-5' $null
  if ($page.limit -ne 500 -or $page.offset -ne 0) { throw "audit paging echoed limit $($page.limit), offset $($page.offset)" }
  Write-Host 'audit paging clamp: OK'
} finally {
  if ($item) { try { Call $admin 'Post' "/api/items/$($item.id)/retire" @{ note = 'smoke cleanup' } | Out-Null } catch {} }
  if ($report) { try { Call $admin 'Delete' "/api/lostfound/$($report.id)" $null | Out-Null } catch {} }
  if ($Auth -eq 'oidc') { Remove-SmokeUser $adminUid; Remove-SmokeUser $roUid }
}

Write-Host 'stash smoke: OK'
