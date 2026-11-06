# Close tasks on the Tasks board (moves them to the space's "done" status),
# or move them to a named status, and optionally leave a comment, e.g. a link
# to the merge request.
# Usage: scripts/tasks-board.ps1 -Close WIKI-4 [-Comment 'MR !12'] [-Base http://localhost:3009/api/v1]
#        scripts/tasks-board.ps1 -Close WIKI-1,WIKI-2,WIKI-3 -Comment 'Shipped earlier; see wiki/docs/plan.md'
#        scripts/tasks-board.ps1 -Status Review -Keys TASK-34,TASK-35 -Comment 'Done in dev; ships at cutover'
param(
  [string[]]$Close,
  [string]$Status = '',
  [string[]]$Keys,
  [string]$Comment = '',
  [string]$Base = 'http://localhost:3009/api/v1'
)
$ErrorActionPreference = 'Stop'
if (-not $Close -and -not ($Status -and $Keys)) {
  throw 'Use -Close KEY[,KEY...] or -Status <name> -Keys KEY[,KEY...]'
}

$kc = 'http://localhost:8085/realms/conservices/protocol/openid-connect/token'
$token = (Invoke-RestMethod -Method Post -Uri $kc -Body @{
    grant_type = 'password'; client_id = 'tasks-spa'; username = 'admin'; password = 'adminadmin'; scope = 'openid'
  }).id_token
$h = @{ Authorization = "Bearer $token" }

function Api($method, $path, $body) {
  $req = @{ Method = $method; Uri = "$Base$path"; Headers = $h }
  if ($null -ne $body) {
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))
  }
  Invoke-RestMethod @req
}

foreach ($key in $Close) {
  $t = Api GET "/tasks/$key"
  if ($t.status.category -eq 'done') {
    Write-Host "$key already done ($($t.title))"
  } else {
    $done = $t.statuses | Where-Object category -eq 'done' | Select-Object -First 1
    if (-not $done) { throw "$($key): the space has no status with category 'done'" }
    $t = Api PATCH "/tasks/$key" @{ status_id = $done.id; version = $t.version }
    Write-Host "$key closed ($($t.title))"
  }
  if ($Comment) {
    Api POST "/tasks/$key/comments" @{ body = $Comment } | Out-Null
    Write-Host "$key commented"
  }
}

if ($Status) {
  foreach ($key in $Keys) {
    $t = Api GET "/tasks/$key"
    if ($t.status.name -eq $Status) {
      Write-Host "$key already in $Status ($($t.title))"
    } else {
      $target = $t.statuses | Where-Object name -eq $Status | Select-Object -First 1
      if (-not $target) { throw "$($key): the space has no status named '$Status'" }
      $t = Api PATCH "/tasks/$key" @{ status_id = $target.id; version = $t.version }
      Write-Host "$key moved to $Status ($($t.title))"
    }
    if ($Comment) {
      Api POST "/tasks/$key/comments" @{ body = $Comment } | Out-Null
      Write-Host "$key commented"
    }
  }
}
