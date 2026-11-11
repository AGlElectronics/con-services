# Smoke: Wiki spaces, pages and sharing against the real stack.
# A throwaway editor (group wiki-editor) creates a closed team space with a
# page tree; a throwaway reader (no Wiki group) cannot see it until a page
# is shared with them, then sees only that page; opening the space to
# everyone lets them in. Admins see every team space but not private ones.
# The Keycloak users are created for the run and deleted at the end; the
# smoke space is deleted too.
$ErrorActionPreference = 'Stop'
$kcBase = 'http://localhost:8085'
$kc = "$kcBase/realms/conservices/protocol/openid-connect/token"
$wiki = 'http://localhost:8140'
# Live editing goes through the frontend nginx to exercise its websocket proxying.
$liveBase = 'ws://localhost:3007'

function Get-AccessToken($user, $pass) {
  $body = @{ grant_type = 'password'; client_id = 'wiki-spa'; username = $user; password = $pass; scope = 'openid profile email' }
  # Token contract: Wiki's API takes access tokens (audience wiki-api), not ID tokens.
  (Invoke-RestMethod -Method Post -Uri $kc -Body $body).access_token
}

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

function Call($headers, $method, $path, $body) {
  if ($null -ne $body) {
    Invoke-RestMethod -Method $method -Uri "$wiki$path" -Headers $headers -ContentType 'application/json; charset=utf-8' `
      -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6)))
  } else {
    Invoke-RestMethod -Method $method -Uri "$wiki$path" -Headers $headers
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

# Live editing client (internal/live/protocol.go): binary frames 1 update,
# 2 batch, 3 awareness; JSON text control messages.
$none = [Threading.CancellationToken]::None
function Receive-Live($ws, $pending) {
  $buf = New-Object byte[] 1048576
  $ms = New-Object IO.MemoryStream
  do {
    # A receive started earlier (Start-Receive) is finished first.
    if ($pending) { $task = $pending.Task; $buf = $pending.Buf; $pending = $null }
    else { $task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $none) }
    try { $ok = $task.Wait(15000) } catch {
      $inner = $_.Exception.InnerException
      # .NET Framework (Windows PowerShell 5) rejects close code 1012
      # ("service restart"), which browsers accept.
      if ($inner -is [Net.WebSockets.WebSocketException] -and $inner.WebSocketErrorCode -eq 'InvalidMessageType' -or
          "$($inner.InnerException.Message)$($inner.Message)" -match 'Invalid data format') {
        return [pscustomobject]@{ Type = 'Close'; Status = 1012; Data = $null }
      }
      throw "live receive failed: $($inner.Message) $($inner.InnerException.Message)"
    }
    if (-not $ok) { throw 'timed out waiting for a live message' }
    $r = $task.Result
    if ($r.MessageType -eq 'Close') { return [pscustomobject]@{ Type = 'Close'; Status = [int]$ws.CloseStatus; Data = $null } }
    $ms.Write($buf, 0, $r.Count)
  } while (-not $r.EndOfMessage)
  [pscustomobject]@{ Type = $r.MessageType.ToString(); Status = 0; Data = $ms.ToArray() }
}
# Browsers answer the server's close at once; .NET only does while receiving.
function Start-Receive($ws) {
  $buf = New-Object byte[] 1048576
  [pscustomobject]@{ Task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $none); Buf = $buf }
}
function Send-Live($ws, [byte[]]$frame) {
  if (-not $ws.SendAsync([ArraySegment[byte]]::new($frame), 'Binary', $true, $none).Wait(10000)) { throw 'live send timed out' }
}
function Join-Live($headers, $pageId) {
  $t = Call $headers 'Post' "/api/v1/pages/$pageId/live-ticket" $null
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $uri = [Uri]"$liveBase/api/v1/pages/$pageId/live?ticket=$([Uri]::EscapeDataString($t.ticket))"
  if (-not $ws.ConnectAsync($uri, $none).Wait(10000) -or $ws.State -ne 'Open') { throw "live connect failed: $($ws.State)" }
  $batch = Receive-Live $ws
  if ($batch.Type -ne 'Binary' -or $batch.Data[0] -ne 2) { throw "expected a batch frame, got $($batch.Type)" }
  $updates = @()
  $d = $batch.Data
  for ($i = 1; $i + 4 -le $d.Length; ) {
    $n = [int]$d[$i] * 16777216 + [int]$d[$i + 1] * 65536 + [int]$d[$i + 2] * 256 + [int]$d[$i + 3]
    $updates += [Text.Encoding]::UTF8.GetString($d, $i + 4, $n)
    $i += 4 + $n
  }
  $synced = Receive-Live $ws
  $msg = [Text.Encoding]::UTF8.GetString($synced.Data) | ConvertFrom-Json
  if ($msg.type -ne 'synced') { throw "expected synced, got $($msg.type)" }
  [pscustomobject]@{ Ws = $ws; Updates = $updates; Level = $msg.level }
}
function Update-Frame($text) { [byte[]](@(1) + [Text.Encoding]::UTF8.GetBytes($text)) }
# Through nginx too: it re-resolves a restarted backend within ~10s.
function Wait-Ready {
  for ($i = 0; $i -lt 60; $i++) {
    try {
      Invoke-RestMethod "$wiki/readyz" | Out-Null
      Invoke-RestMethod "$($liveBase -replace '^ws', 'http')/readyz" | Out-Null
      return
    } catch { Start-Sleep -Milliseconds 500 }
  }
  throw 'wiki backend did not come back'
}

$editorUid = Ensure-SmokeUser 'smoke-wiki-editor' 'smoke-wiki-editor-pass' 'wiki-editor'
$readerUid = Ensure-SmokeUser 'smoke-wiki-reader' 'smoke-wiki-reader-pass' $null
$space = $null
try {
  $editor = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-wiki-editor' 'smoke-wiki-editor-pass')" }
  $reader = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-wiki-reader' 'smoke-wiki-reader-pass')" }
  $admin = @{ Authorization = "Bearer $(Get-AccessToken 'admin' 'adminadmin')" }

  $me = Call $editor 'Get' '/api/v1/me'
  if ($me.permissions -notcontains 'space.create') { throw 'smoke-wiki-editor is missing space.create (wiki-editor group not mapped?)' }
  $readerMe = Call $reader 'Get' '/api/v1/me'
  if ($readerMe.permissions.Count -ne 0) { throw "reader has permissions: $($readerMe.permissions -join ',')" }
  Expect-Status 403 $reader 'Post' '/api/v1/spaces' @{ name = 'Nope' } 'reader creates space'

  $catalog = Invoke-RestMethod -Uri "$wiki/api/role-catalog"
  if ($catalog.module -ne 'wiki') { throw 'role catalog module mismatch' }
  Write-Host "role catalog: $(($catalog.roles | ForEach-Object key) -join ',')"

  # Everyone gets a private space; admins cannot see other people's.
  $editorPrivate = (Call $editor 'Get' '/api/v1/spaces').spaces | Where-Object kind -eq 'private'
  if (-not $editorPrivate) { throw 'editor has no private space' }
  Expect-Status 404 $admin 'Get' "/api/v1/spaces/$($editorPrivate.id)" $null 'admin reads editor private space'

  # Closed team space with Handbook > Secret.
  $stamp = Get-Date -Format 'HHmmss'
  $space = Call $editor 'Post' '/api/v1/spaces' @{ name = "Smoke wiki $stamp"; icon = 'S' }
  $handbook = Call $editor 'Post' "/api/v1/spaces/$($space.id)/pages" @{ title = 'Handbook' }
  $secret = Call $editor 'Post' "/api/v1/spaces/$($space.id)/pages" @{ title = 'Secret'; parent_id = $handbook.id }
  Write-Host "space $($space.id): Handbook=$($handbook.id) Secret=$($secret.id)"

  Expect-Status 404 $reader 'Get' "/api/v1/spaces/$($space.id)" $null 'reader reads closed space'
  Expect-Status 404 $reader 'Get' "/api/v1/pages/$($handbook.id)" $null 'reader reads page in closed space'

  # Admin (wiki.manage) has full access to every team space.
  $adminView = Call $admin 'Get' "/api/v1/spaces/$($space.id)"
  if ($adminView.access -ne 'full') { throw "admin access is $($adminView.access), expected full" }

  # Share Secret with the reader: they see Secret, not Handbook.
  # Earlier runs leave wiki users with the same email, so match on id.
  $readerId = $readerMe.id
  $people = (Call $editor 'Get' '/api/v1/users?q=smoke-wiki-reader').people
  if (-not ($people | Where-Object { $_.id -eq $readerId })) { throw 'reader not found in people search' }
  if ($people | Where-Object { $_.email }) { throw 'a non-admin sees email addresses in the people picker' }
  Call $editor 'Put' "/api/v1/pages/$($secret.id)/grants" @{ principal_kind = 'user'; principal = $readerId; level = 'view' } | Out-Null
  $shared = (Call $reader 'Get' '/api/v1/spaces').shared
  if (-not ($shared | Where-Object { $_.id -eq $secret.id })) { throw 'Secret missing from the reader''s shared list' }
  $readerSecret = Call $reader 'Get' "/api/v1/pages/$($secret.id)"
  if ($readerSecret.access -ne 'view' -or $readerSecret.breadcrumbs.Count -ne 0) { throw 'reader should see Secret with view access and no hidden breadcrumbs' }
  Expect-Status 404 $reader 'Get' "/api/v1/pages/$($handbook.id)" $null 'reader reads unshared parent'
  Expect-Status 403 $reader 'Patch' "/api/v1/pages/$($secret.id)" @{ title = 'hijack' } 'reader edits shared page'

  # Opening the space to everyone lets the reader in.
  Call $editor 'Patch' "/api/v1/spaces/$($space.id)" @{ everyone_level = 'view' } | Out-Null
  $tree = Call $reader 'Get' "/api/v1/spaces/$($space.id)/pages"
  if ($tree.pages.Count -ne 2) { throw "reader sees $($tree.pages.Count) pages, expected 2" }

  # Restricting Handbook hides it (and Secret's inherited access) again.
  Call $editor 'Put' "/api/v1/pages/$($handbook.id)/restricted" @{ restricted = $true } | Out-Null
  Expect-Status 404 $reader 'Get' "/api/v1/pages/$($handbook.id)" $null 'reader reads restricted page'
  $adminHandbook = Call $admin 'Get' "/api/v1/pages/$($handbook.id)"
  if ($adminHandbook.access -ne 'full') { throw 'admin lost access to a restricted page' }

  # Trash and restore.
  Call $editor 'Post' "/api/v1/pages/$($handbook.id)/trash" $null | Out-Null
  Expect-Status 404 $editor 'Get' "/api/v1/pages/$($secret.id)" $null 'editor reads page under trashed parent'
  Call $editor 'Post' "/api/v1/pages/$($handbook.id)/restore" $null | Out-Null
  Call $editor 'Get' "/api/v1/pages/$($secret.id)" | Out-Null
  Write-Host 'trash and restore: OK'

  # Live editing: the editor's change reaches the reader (view only), the
  # reader's is refused, and the change survives a backend restart.
  $a = Join-Live $editor $secret.id
  $b = Join-Live $reader $secret.id
  if ($a.Level -ne 'full' -or $b.Level -ne 'view') { throw "live levels: editor $($a.Level), reader $($b.Level)" }
  $change = "smoke-change-$stamp"
  Send-Live $a.Ws (Update-Frame $change)
  $got = Receive-Live $b.Ws
  if ($got.Type -ne 'Binary' -or [Text.Encoding]::UTF8.GetString($got.Data, 1, $got.Data.Length - 1) -ne $change) {
    throw 'the reader did not receive the editor''s change'
  }
  Send-Live $b.Ws (Update-Frame 'reader-change')
  $refused = [Text.Encoding]::UTF8.GetString((Receive-Live $b.Ws).Data) | ConvertFrom-Json
  if ($refused.type -ne 'error') { throw 'a view-only change should be refused' }
  Write-Host 'live relay through nginx: OK'

  $pending = Start-Receive $a.Ws
  docker restart conservices-wiki-backend | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'could not restart conservices-wiki-backend' }
  $closed = Receive-Live $a.Ws $pending
  if ($closed.Type -ne 'Close' -or $closed.Status -ne 1012) { throw "expected close 1012 on restart, got $($closed.Type) $($closed.Status)" }
  Wait-Ready
  $again = Join-Live $editor $secret.id
  if ($again.Updates -notcontains $change) { throw "the change was lost across the restart (stored: $($again.Updates -join ','))" }
  if ($again.Updates -contains 'reader-change') { throw 'a refused change was stored' }
  $again.Ws.Dispose()
  Write-Host 'live edits survive a restart: OK'

  # Refresh tokens: the restart check above can outlive short token lives.
  $editor = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-wiki-editor' 'smoke-wiki-editor-pass')" }
  $reader = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-wiki-reader' 'smoke-wiki-reader-pass')" }
  $admin = @{ Authorization = "Bearer $(Get-AccessToken 'admin' 'adminadmin')" }

  # Uploads ride on page access: the editor uploads, the reader downloads
  # a shared page's file, and no access reads as 404.
  function Upload-File($headers, $pageId, $name, $contentType, [byte[]]$bytes) {
    $client = New-Object System.Net.Http.HttpClient
    try {
      $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::Parse($headers.Authorization)
      $mp = New-Object System.Net.Http.MultipartFormDataContent
      $fc = New-Object System.Net.Http.ByteArrayContent(, $bytes)
      $fc.Headers.ContentType = $contentType
      $mp.Add($fc, 'file', $name)
      $res = $client.PostAsync("$wiki/api/v1/pages/$pageId/files", $mp).Result
      if ([int]$res.StatusCode -ne 201) { throw "upload returned $([int]$res.StatusCode)" }
      $res.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    } finally { $client.Dispose() }
  }
  $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [Text.Encoding]::UTF8.GetBytes("png-$stamp")
  $file = Upload-File $editor $secret.id 'smoke.png' 'image/png' $png
  $res = Invoke-WebRequest -UseBasicParsing -Uri "$wiki$($file.url)" -Headers $reader
  if ([Convert]::ToBase64String($res.Content) -ne [Convert]::ToBase64String($png)) { throw 'the reader downloaded different bytes' }
  if ($res.Headers['Content-Disposition'] -notlike 'inline*' -or $res.Headers['Content-Security-Policy'] -ne 'sandbox') {
    throw "a PNG should open inline in a sandbox: $($res.Headers['Content-Disposition']) / $($res.Headers['Content-Security-Policy'])"
  }
  # Active content never renders on the wiki's address.
  $svg = Upload-File $editor $secret.id 'smoke.svg' 'image/svg+xml' ([Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'))
  $res = Invoke-WebRequest -UseBasicParsing -Uri "$wiki$($svg.url)" -Headers $reader
  if ($res.Headers['Content-Disposition'] -notlike 'attachment*' -or $res.Headers['Content-Security-Policy'] -ne 'sandbox' -or $res.Headers['X-Content-Type-Options'] -ne 'nosniff') {
    throw 'an SVG must download as a sandboxed attachment'
  }
  $fake = Upload-File $editor $secret.id 'fake.png' 'image/png' ([Text.Encoding]::UTF8.GetBytes('<html><script>alert(1)</script></html>'))
  if ($fake.content_type -ne 'application/octet-stream') { throw "HTML claiming to be a PNG was stored as $($fake.content_type)" }
  Write-Host 'file upload, access-checked download, sandboxed active content: OK'

  # Search finds by title, filtered by access.
  $needle = "pumpkin$stamp"
  $editorPrivatePage = Call $editor 'Post' "/api/v1/spaces/$($editorPrivate.id)/pages" @{ title = "Secret $needle plan" }
  $hits = (Call $editor 'Get' "/api/v1/search?q=$needle").hits
  if (-not ($hits | Where-Object { $_.id -eq $editorPrivatePage.id })) { throw 'search missed a title match' }
  $readerHits = (Call $reader 'Get' "/api/v1/search?q=$needle").hits
  if ($readerHits.Count -ne 0) { throw 'search leaked a private page to the reader' }
  Write-Host 'search with access filtering: OK'

  # Comments: editors anchor threads to text, the comment level starts
  # page-level discussions and replies, view only reads.
  $body = @{ body = @(@{ type = 'paragraph'; content = 'does this look right?' }) }
  $thread = Call $editor 'Post' "/api/v1/pages/$($secret.id)/threads" $body
  if (-not $thread.anchored) { throw 'an editor''s thread should be anchored' }
  Expect-Status 403 $reader 'Post' "/api/v1/threads/$($thread.id)/comments" $body 'view-only reader replies'
  Call $editor 'Put' "/api/v1/pages/$($secret.id)/grants" @{ principal_kind = 'user'; principal = $readerId; level = 'comment' } | Out-Null
  Call $reader 'Post' "/api/v1/threads/$($thread.id)/comments" @{ body = @(@{ type = 'paragraph'; content = 'yes' }) } | Out-Null
  $resolved = Call $reader 'Post' "/api/v1/threads/$($thread.id)/resolve" $null
  if (-not $resolved.resolved) { throw 'the thread should be resolved' }
  Expect-Status 403 $reader 'Post' "/api/v1/pages/$($secret.id)/threads" $body 'comment level anchors a thread to text'
  $discussion = Call $reader 'Post' "/api/v1/pages/$($secret.id)/threads" @{ body = $body.body; anchored = $false }
  if ($discussion.anchored) { throw 'a page-level discussion should not be anchored' }
  Call $editor 'Delete' "/api/v1/threads/$($thread.id)" $null | Out-Null
  Call $editor 'Delete' "/api/v1/threads/$($discussion.id)" $null | Out-Null
  Write-Host 'comments (inline for editors, page discussions for comment level, resolve): OK'

  # Duplicate (templates machinery): the copy carries the content.
  $copy = (Call $editor 'Post' "/api/v1/pages/$($secret.id)/duplicate" @{}).page
  if ($copy.title -ne 'Secret (copy)') { throw "duplicate title is $($copy.title)" }
  $copyLive = Join-Live $editor $copy.id
  if ($copyLive.Updates -notcontains $change) { throw 'the duplicate lost the page content' }
  $copyLive.Ws.Dispose()
  Write-Host 'duplicate with content: OK'

  # Databases: schema, a row, a value, a filtered view.
  $db = Call $editor 'Post' "/api/v1/spaces/$($space.id)/pages" @{ title = 'Smoke tracker'; kind = 'database' }
  $prop = Call $editor 'Post' "/api/v1/pages/$($db.id)/properties" @{ name = 'Status'; type = 'select'; options = @{ choices = @('Todo', 'Done') } }
  $row = Call $editor 'Post' "/api/v1/spaces/$($space.id)/pages" @{ title = 'Try the smoke'; parent_id = $db.id }
  Call $editor 'Put' "/api/v1/pages/$($row.id)/values" @{ values = @{ "$($prop.id)" = 'Todo' } } | Out-Null
  $rows = (Call $editor 'Get' "/api/v1/pages/$($db.id)/rows").rows
  if ($rows.Count -ne 1 -or $rows[0].values."$($prop.id)" -ne 'Todo') { throw "database rows: $($rows | ConvertTo-Json -Depth 5)" }
  Write-Host 'database (schema, row, value): OK'

  # Public share links. The org switch (Den wiki_public_links /
  # PUBLIC_LINKS_ENABLED) decides whether the public URL answers.
  $link = Call $editor 'Post' "/api/v1/pages/$($secret.id)/share-links" @{ include_children = $false; expires_in_days = 1 }
  try {
    $shareView = Invoke-RestMethod -Uri "$wiki/api/public/v1/shares/$($link.token)"
    if ($shareView.page.id -ne $secret.id) { throw 'the share shows the wrong page' }
    Call $editor 'Delete' "/api/v1/share-links/$($link.link.id)" $null | Out-Null
    try {
      Invoke-RestMethod -Uri "$wiki/api/public/v1/shares/$($link.token)" | Out-Null
      throw 'a revoked share link still answers'
    } catch { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
    Write-Host 'public share links (view + revoke): OK'
  } catch {
    if ([int]$_.Exception.Response.StatusCode -eq 404) {
      Write-Host 'public share links are switched off for this stack (uniform 404): OK'
    } else { throw }
  }

  # Offboarding: HR's hook orphans the private space; the admin sees it,
  # exports what matters and may delete it right away.
  $victimUid = Ensure-SmokeUser 'smoke-wiki-victim' 'smoke-wiki-victim-pass' $null
  try {
    $victim = @{ Authorization = "Bearer $(Get-AccessToken 'smoke-wiki-victim' 'smoke-wiki-victim-pass')" }
    $victimPrivate = (Call $victim 'Get' '/api/v1/spaces').spaces | Where-Object kind -eq 'private'
    Call $victim 'Post' "/api/v1/spaces/$($victimPrivate.id)/pages" @{ title = 'Leaving notes' } | Out-Null
    Expect-Status 404 $admin 'Get' "/api/v1/spaces/$($victimPrivate.id)" $null 'admin reads a live private space'
    $hookToken = 'wiki-service-dev-token'
    Invoke-RestMethod -Method Post -Uri "$wiki/api/internal/offboarded" `
      -Headers @{ Authorization = "Bearer $hookToken" } -ContentType 'application/json' `
      -Body (@{ issuer = 'https://auth.conservices.test/realms/conservices'; subject = $victimUid; username = 'smoke-wiki-victim' } | ConvertTo-Json) | Out-Null
    $orphanView = Call $admin 'Get' "/api/v1/spaces/$($victimPrivate.id)"
    if (-not $orphanView.orphaned_at) { throw 'the orphaned space has no stamp' }
    Call $admin 'Delete' "/api/v1/spaces/$($victimPrivate.id)" $null | Out-Null
    Write-Host 'offboarding (hook, admin access, delete): OK'
  } finally {
    Remove-SmokeUser $victimUid
  }
} finally {
  if ($space) { try { Call $admin 'Delete' "/api/v1/spaces/$($space.id)" $null | Out-Null } catch {} }
  Remove-SmokeUser $editorUid
  Remove-SmokeUser $readerUid
}

Write-Host 'wiki smoke: OK'
