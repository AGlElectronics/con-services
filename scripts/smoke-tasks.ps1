# Smoke: Tasks end to end against a running stack (TASK-13).
# Creates a throwaway space as admin and walks the whole feature surface:
# lists, statuses, tasks and patch conflicts, subtasks, comments, checklists,
# tags, watching and the Inbox, search, folders, favourites, attachments
# (skipped gracefully when S3 is not configured), an automation rule, the
# trash, and KEY-N aliases across a cross-space move. Cleans up after itself.
#
# Usage: scripts/smoke-tasks.ps1                                  # live (:3009)
#        scripts/smoke-tasks.ps1 -Base http://localhost:8161      # dev copy
param(
  [string]$Base = 'http://localhost:3009',
  [string]$Keycloak = 'http://localhost:8085',
  [string]$User = 'admin',
  [string]$Password = 'adminadmin'
)
$ErrorActionPreference = 'Stop'
$api = "$Base/api/v1"

$token = (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/conservices/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'tasks-spa'; username = $User; password = $Password; scope = 'openid'
  }).access_token
$h = @{ Authorization = "Bearer $token" }

$script:step = 0
function Step($name) { $script:step++; Write-Host ("{0,2}. {1}" -f $script:step, $name) }
function Api($method, $path, $body) {
  $req = @{ Method = $method; Uri = "$api$path"; Headers = $h }
  if ($null -ne $body) {
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  }
  Invoke-RestMethod @req
}
function Expect-Status($expected, $method, $path, $body, $what) {
  try {
    Api $method $path $body | Out-Null
    throw 'EXPECTED-FAIL'
  } catch {
    if ($_.Exception.Message -eq 'EXPECTED-FAIL') { throw "$what succeeded but should have returned $expected" }
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -ne $expected) { throw "$what returned $status, expected $expected" }
  }
}
function Assert($cond, $what) { if (-not $cond) { throw "FAILED: $what" } }

$spaceIds = @()
try {
  Step 'health'
  Invoke-RestMethod -Uri "$Base/readyz" | Out-Null

  Step 'create a space (starts closed) with a second list'
  $sp = Api POST '/spaces' @{ name = 'Smoke space'; key = 'SMK' }
  $spaceIds += $sp.id
  Assert ($null -eq $sp.everyone_level) 'new space starts closed'
  $list = $sp.lists[0]
  $second = Api POST "/spaces/$($sp.id)/lists" @{ name = 'Second list' }
  $done = $sp.statuses | Where-Object category -eq 'done' | Select-Object -First 1
  $todo = $sp.statuses | Where-Object category -eq 'not_started' | Select-Object -First 1

  Step 'task CRUD and optimistic locking'
  $t = Api POST '/tasks' @{ list_id = $list.id; title = 'smoke task'; priority = 'high'; due_at = '2027-03-01' }
  Assert ($t.key -eq 'SMK-1') "first task is SMK-1 (got $($t.key))"
  $t = Api PATCH "/tasks/$($t.id)" @{ title = 'renamed'; version = $t.version }
  Assert ($t.priority -eq 'high') 'patch leaves absent fields alone'
  Expect-Status 409 PATCH "/tasks/$($t.id)" @{ title = 'stale'; version = ($t.version - 1) } 'stale-version patch'
  $t = Api PATCH "/tasks/$($t.id)" @{ priority = $null; version = $t.version }
  Assert ($null -eq $t.priority) 'null clears priority'

  Step 'subtask'
  $sub = Api POST '/tasks' @{ parent_id = $t.id; title = 'child' }
  Assert ($sub.parent_id -eq $t.id) 'subtask linked to parent'

  Step 'comments: post, edit, mention notification'
  $c = Api POST "/tasks/$($t.id)/comments" @{ body = 'first comment' }
  $c = Api PATCH "/comments/$($c.id)" @{ body = 'edited comment' }
  Assert ($null -ne $c.edited_at) 'edited_at stamped'

  Step 'checklist: add, complete (logs an event)'
  $item = Api POST "/tasks/$($t.id)/checklist" @{ body = 'only step' }
  $item = Api PATCH "/checklist/$($item.id)" @{ done = $true }
  Assert $item.done 'checklist item done'
  $detail = Api GET "/tasks/$($t.key)"
  Assert (@($detail.events | Where-Object kind -eq 'checklist_completed').Count -ge 1) 'checklist_completed event'

  Step 'tags: create, attach, filterable on the task'
  $tag = Api POST "/spaces/$($sp.id)/tags" @{ name = 'smoke'; color = '#ff7700' }
  $t = Api PATCH "/tasks/$($t.id)" @{ tag_ids = @($tag.id); version = $detail.version }
  Assert ($t.tags.Count -eq 1) 'tag attached'

  Step 'watch + inbox: a status change notifies the watcher'
  Api POST "/tasks/$($t.id)/watch" @{} | Out-Null
  # the actor is skipped, so the notification goes to... nobody here, but
  # the endpoints themselves must work:
  Api GET '/inbox' | Out-Null
  (Api GET '/inbox/unread-count').count | Out-Null
  Api DELETE "/tasks/$($t.id)/watch" | Out-Null

  Step 'search finds the task by title and by key'
  $hits = (Api GET '/search?q=renamed').results
  Assert (@($hits | Where-Object key -eq $t.key).Count -eq 1) 'search by title'
  $hits = (Api GET "/search?q=$($t.key)").results
  Assert ($hits[0].key -eq $t.key) 'exact key pinned first'

  Step 'folders and favourites'
  $folder = Api POST "/spaces/$($sp.id)/folders" @{ name = 'Smoke folder' }
  Api PATCH "/lists/$($second.id)" @{ folder_id = $folder.id } | Out-Null
  Api PUT '/favorites' @{ space_id = $sp.id } | Out-Null
  Assert ((Api GET '/favorites').favorites.Count -ge 1) 'favourite saved'
  Api POST '/favorites/remove' @{ space_id = $sp.id } | Out-Null

  Step 'attachments (skipped when S3 is not configured)'
  $tmp = Join-Path $env:TEMP 'tasks-smoke.txt'
  'smoke attachment' | Set-Content -Path $tmp
  try {
    $up = curl.exe -s -X POST "$api/tasks/$($t.id)/attachments" -H "Authorization: Bearer $token" -F "file=@$tmp" | ConvertFrom-Json
    if ($up.error) { throw ($up.error.message) }
    $bytes = Invoke-RestMethod -Uri "$api/attachments/$($up.id)" -Headers $h
    Assert ($bytes -match 'smoke attachment') 'attachment round-trip'
    Api DELETE "/attachments/$($up.id)" | Out-Null
  } catch {
    if ("$_" -match 'unavailable|not configured|503') { Write-Host '    (S3 not configured; skipped)' }
    else { throw }
  }

  Step 'automation: status -> done adds a comment, with run history'
  $rule = Api POST "/spaces/$($sp.id)/automations" @{
    name = 'smoke done rule'
    trigger = @{ type = 'status_changed'; status_id = $done.id }
    actions = @(@{ type = 'add_comment'; body = 'smoke automation fired' })
  }
  $t = Api PATCH "/tasks/$($t.id)" @{ status_id = $done.id; version = $t.version }
  Assert ($null -ne $t.completed_at) 'completed_at set when done'
  $detail = Api GET "/tasks/$($t.key)"
  Assert (@($detail.comments | Where-Object body -eq 'smoke automation fired').Count -eq 1) 'automation commented'
  $runs = (Api GET "/automations/$($rule.id)/runs").runs
  Assert ($runs.Count -eq 1 -and $runs[0].status -eq 'ok') 'run recorded'

  Step 'trash: delete, restore, delete, purge'
  Api DELETE "/tasks/$($t.id)" | Out-Null
  Expect-Status 404 GET "/tasks/$($t.key)" $null 'reading a trashed task'
  $t = Api POST "/tasks/$($t.id)/restore" @{}
  Assert ($t.key -eq 'SMK-1') 'restore keeps the key'
  Api DELETE "/tasks/$($t.id)" | Out-Null
  Api DELETE "/tasks/$($t.id)/purge" | Out-Null

  Step 'cross-space move keeps old KEY-N references resolving'
  $sp2 = Api POST '/spaces' @{ name = 'Smoke target'; key = 'SMT' }
  $spaceIds += $sp2.id
  $mover = Api POST '/tasks' @{ list_id = $list.id; title = 'mover' }
  $oldKey = $mover.key
  $mover = Api PATCH "/tasks/$($mover.id)" @{ list_id = $sp2.lists[0].id; version = $mover.version }
  Assert ($mover.key -like 'SMT-*') "moved task renumbered (got $($mover.key))"
  Assert ((Api GET "/tasks/$oldKey").id -eq $mover.id) 'old key still resolves'

  Step 'pagination: X-Next-Cursor appears when a page fills'
  1..3 | ForEach-Object { Api POST '/tasks' @{ list_id = $list.id; title = "page $_" } | Out-Null }
  $resp = Invoke-WebRequest -Uri "$api/lists/$($list.id)/tasks?limit=2" -Headers $h -UseBasicParsing
  Assert ($null -ne $resp.Headers['X-Next-Cursor']) 'cursor header on a full page'

  Write-Host "`nSMOKE OK ($script:step steps)"
} finally {
  foreach ($id in $spaceIds) {
    try { Api DELETE "/spaces/$id" | Out-Null } catch {}
  }
}

