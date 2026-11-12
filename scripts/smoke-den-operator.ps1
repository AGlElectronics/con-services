# Smoke: Den's operator end to end through Den's API.
#   - the ops role: alice (admin without den-ops) may read the status but not run backups
#   - a scratch module with a Den-created database, a manual backup, a one-time
#     download link that works exactly once, and removing the module with its
#     database (backed up first)
#   - the audit log records it, and both containers pass their healthcheck
# Usage: scripts/smoke-den-operator.ps1        (Compose stack with --profile den)
#        scripts/smoke-den-operator.ps1 -KeepModule   (skip the removal at the end)
# Uses the dev realm accounts admin/adminadmin (den-admin + den-ops) and
# alice/alicealice (den-admin only). DEV ONLY.
param([switch]$KeepModule)
$ErrorActionPreference = 'Stop'
$kc = 'http://localhost:8085/realms/conservices/protocol/openid-connect/token'
$den = 'http://localhost:3001'

function Get-Token($user, $password) {
  (Invoke-RestMethod -Method Post -Uri $kc -Body @{ grant_type = 'password'; client_id = 'den-spa'; username = $user; password = $password; scope = 'openid' }).access_token
}
function Get-Status($code) {
  # Invoke-WebRequest throws on 4xx/5xx; return the status code either way.
  try { (Invoke-WebRequest @code -UseBasicParsing).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
}
$ops = @{ Authorization = "Bearer $(Get-Token 'admin' 'adminadmin')" }
$adminOnly = @{ Authorization = "Bearer $(Get-Token 'alice' 'alicealice')" }
$started = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')

# 0. Health checks of the distroless images.
foreach ($c in @(@('conservices-den-backend', '/den-server'), @('conservices-den-operator', 'den-operator'))) {
  $out = docker exec $c[0] $c[1] healthcheck 2>&1
  if ($LASTEXITCODE -ne 0) { throw "$($c[0]) healthcheck failed: $out" }
}
Write-Host 'Healthchecks: den-backend and den-operator ok'

# 1. Roles: ops may, admin alone may not.
$me = Invoke-RestMethod -Uri "$den/api/v1/me" -Headers $ops
if ($me.roles -notcontains 'ops') { throw "admin has no ops role (is admin in den-ops?): $($me.roles -join ',')" }
if ((Get-Status @{ Uri = "$den/api/v1/operations/status"; Headers = $adminOnly }) -ne 200) { throw 'alice should read the operations status' }
if ((Get-Status @{ Uri = "$den/api/v1/operations/backups"; Headers = $adminOnly }) -ne 403) { throw 'alice (no ops role) must not list backups' }
if ((Get-Status @{ Uri = "$den/api/v1/operations/backups"; Method = 'Post'; Headers = $adminOnly }) -ne 403) { throw 'alice (no ops role) must not start backups' }
Write-Host 'Roles: admin without ops sees the status only'

$status = Invoke-RestMethod -Uri "$den/api/v1/operations/status" -Headers $ops
if (-not $status.configured -or -not $status.reachable) { throw "operator not reachable: $($status | ConvertTo-Json -Compress)" }
if (-not $status.managed_databases -or -not $status.backups_enabled) { throw 'this smoke needs MANAGED_DATABASES=true and BACKUP_ENABLED=true' }
Write-Host "Operator reachable: $($status.databases.Count) databases, backups to $($status.target)"

# 2. A scratch module with a database Den creates.
$slug = "smoke-op-$(Get-Date -Format 'HHmmss')"
$created = Invoke-RestMethod -Method Post -Uri "$den/api/v1/modules" -Headers $ops -ContentType 'application/json' `
  -Body (@{ slug = $slug; display_name = 'Operator smoke'; create_database = $true } | ConvertTo-Json)
$dbName = $created.database.name
if (-not $dbName -or -not $created.database.database_url) { throw "no database in the create answer: $($created | ConvertTo-Json -Compress)" }
$mod = Invoke-RestMethod -Uri "$den/api/v1/modules/$($created.id)" -Headers $ops
if (-not $mod.database_created_by_den) { throw 'database_created_by_den should be true' }
$status = Invoke-RestMethod -Uri "$den/api/v1/operations/status" -Headers $ops
if (-not ($status.databases | Where-Object { $_.name -eq $dbName })) { throw "database $dbName not on the server" }
Write-Host "Module $slug created with database $dbName"

# 3. A manual backup, waited for.
Invoke-RestMethod -Method Post -Uri "$den/api/v1/operations/backups" -Headers $ops | Out-Null
$deadline = (Get-Date).AddMinutes(5)
do {
  Start-Sleep -Seconds 3
  $status = Invoke-RestMethod -Uri "$den/api/v1/operations/status" -Headers $ops
} while ($status.running -and (Get-Date) -lt $deadline)
if ($status.running) { throw 'backup still running after 5 minutes' }
if (-not $status.last.ok -or $status.last.kind -ne 'manual') { throw "manual backup failed: $($status.last | ConvertTo-Json -Compress)" }
if ($status.last.databases -notcontains $dbName) { throw "backup does not contain $dbName" }
Write-Host "Backup ok: $($status.last.key) ($($status.last.size_bytes) bytes)"

# 4. A one-time download link: works once, then 404.
$link = Invoke-RestMethod -Method Post -Uri "$den/api/v1/operations/backups/download-link" -Headers $ops -ContentType 'application/json' `
  -Body (@{ key = $status.last.key } | ConvertTo-Json)
$file = Join-Path ([IO.Path]::GetTempPath()) 'den-smoke-backup.tar.age'
Invoke-WebRequest -Uri "$den$($link.url)" -OutFile $file -UseBasicParsing
$head = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file), 0, 21)
Remove-Item $file
if ($head -ne 'age-encryption.org/v1') { throw "the download is not an age file: '$head'" }
if ((Get-Status @{ Uri = "$den$($link.url)" }) -ne 404) { throw 'a download link must work only once' }
Write-Host 'Download link: age file received, second use refused'

# 5. Remove the module and its database (backed up first).
if ($KeepModule) {
  Write-Host "Keeping $slug (and database $dbName)"
} else {
  $removed = Invoke-RestMethod -Method Delete -Uri "$den/api/v1/modules/$($created.id)?database=drop&confirm=$slug" -Headers $ops
  if (-not $removed.database_dropped -or -not $removed.backup_key) { throw "drop failed: $($removed | ConvertTo-Json -Compress)" }
  $status = Invoke-RestMethod -Uri "$den/api/v1/operations/status" -Headers $ops
  if ($status.databases | Where-Object { $_.name -eq $dbName }) { throw "database $dbName still exists" }
  Write-Host "Removed $slug; database dropped after backup $($removed.backup_key)"
}

# 6. The audit log has it all.
$events = (Invoke-RestMethod -Uri "$den/api/v1/audit-events?since=$started&limit=200" -Headers $ops).items
$want = @('module.create', 'operations.backup.start', 'operations.download_link.create', 'operations.backup.download')
if (-not $KeepModule) { $want += 'module.delete' }
foreach ($a in $want) {
  if (-not ($events | Where-Object { $_.action -eq $a })) { throw "audit log has no $a since $started" }
}
Write-Host "Audit log records: $($want -join ', ')"
Write-Host 'Operator smoke passed'
