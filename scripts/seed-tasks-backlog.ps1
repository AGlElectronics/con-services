# Seed Tasks with one space per module and the suite's open to-dos.
# Idempotent: existing spaces (by key), lists and tasks (by title) are kept.
# Usage: scripts/seed-tasks-backlog.ps1 [-Base http://localhost:3009/api/v1]
param([string]$Base = 'http://localhost:3009/api/v1')
$ErrorActionPreference = 'Stop'

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

# Task entry: title | priority (urgent/high/normal/low or '') | description
function T($title, $priority = '', $description = '') { @{ title = $title; priority = $priority; description = $description } }

$verify = 'From the module docs; check it is still open before starting.'

$backlog = [ordered]@{
  OPS = @{
    name = 'Platform & operations'; color = '#64748b'
    description = 'Shared infrastructure: Postgres, Keycloak, proxy, backups, deployment.'
    lists = [ordered]@{
      'Production checklist' = @(
        (T 'Generate our own age key pair and store the secret key offline in two places' 'high' 'docs/operations.md, production checklist.'),
        (T 'Put the backup bucket at a different provider or account than the live data' 'high'),
        (T 'Set a long random OPERATOR_TOKEN; do not publish the operator port' 'high' 'Add a network policy if running on Kubernetes.'),
        (T 'Make FILES_S3_BUCKETS list every module bucket' 'normal'),
        (T 'Confirm Den admin → Backups shows a successful backup the next morning' 'normal'),
        (T 'Do one test restore into a scratch database' 'normal'),
        (T 'Give standalone modules (or modules on other servers) their own backups' 'normal')
      )
      'Suite' = @(
        (T 'Make sure Den backups include the new desk and tasks databases' 'high' 'Desk and Tasks were registered with create_database=false; check the operator backs up their databases.'),
        (T 'Kubernetes manifests for Desk and Tasks' 'normal' 'Same shape as Den and Rally.'),
        (T 'Replace MinIO with managed S3 in production' 'normal' 'MinIO is dev only (ADR in den/hr).')
      )
    }
  }
  DEN = @{
    name = 'Den'; color = '#6366f1'
    description = 'The portal: dashboard, organisation settings, module pairing, backups.'
    lists = [ordered]@{
      'Backlog' = @(
        (T 'Move the submission site host and attendee OIDC settings for Events into Den' 'normal' 'Rally reads them from env today (Rally/docs/poc-requirements.md).'),
        (T 'Show open Tasks and Desk work in the dashboard to-do widget' 'low' 'Assigned tasks from My Work, unassigned tickets for agents.')
      )
    }
  }
  HR = @{
    name = 'HR'; color = '#ec4899'
    description = 'People, departments, onboarding and access provisioning.'
    lists = [ordered]@{
      'Backlog' = @(
        (T 'Real Google Workspace connector' 'normal' 'hr/backend/internal/provisioners/workspace.go is still a fake.'),
        (T 'Run provisioning in a background job instead of in the request' 'low' $verify),
        (T 'Pagination and search on people and drafts' 'low' $verify)
      )
    }
  }
  STASH = @{
    name = 'Stash'; color = '#f59e0b'
    description = 'Inventory, sign-outs and lost & found.'
    lists = [ordered]@{
      'Lost & found Telegram' = @(
        (T 'Create the Telegram bot and store TELEGRAM_BOT_TOKEN as a secret' 'normal' 'stash/docs/feature-lostfound-telegram-notify.md'),
        (T 'Link a guest chat to a report via /start LF0042 and store telegram_chat_id' 'normal'),
        (T 'Add "Notify guest" on the lost & found detail page (permission lostfound.notify)' 'normal' 'POST /api/lostfound/{id}/notify-telegram; staff confirm the match first.'),
        (T 'Audit log for every Telegram notification' 'normal'),
        (T 'Delete chat IDs after the convention (GDPR)' 'low')
      )
      'Security hardening' = @(
        (T 'P0: production baseline (OIDC only, private bucket, TLS, secrets, CORS allowlist)' 'high' 'stash/docs/security-hardening-plan.md'),
        (T 'P1: ingress rate limiting and file access checks' 'normal'),
        (T 'P2: dependency scanning in CI and CSP headers' 'low')
      )
    }
  }
  EVT = @{
    name = 'Events'; color = '#0ea5e9'
    description = 'Rally: call for papers, programme and editions.'
    lists = [ordered]@{
      'Backlog' = @(
        (T 'Production Helm chart' 'low' 'Rally/docs/adr/0005-k8s-shaped-later.md: manifests are K8s-shaped, chart later.'),
        (T 'Link Rally attendees to Desk conversations' 'low' 'Listed under "out of the first slice" in desk/docs/plan.md.')
      )
    }
  }
  LRN = @{
    name = 'Learn'; color = '#22c55e'
    description = 'Courses, enrolment, quizzes and qualifications.'
    lists = [ordered]@{
      'Later' = @(
        (T 'Forums or discussion per course' 'low' $verify),
        (T 'Cohorts' 'low' $verify),
        (T 'Badges' 'low' $verify)
      )
    }
  }
  FIN = @{
    name = 'Finance'; color = '#14b8a6'
    description = 'Invoices, payments and expenses.'
    lists = [ordered]@{
      'Backlog' = @(
        (T 'Bank feed: import transactions and match them to payments' 'normal' 'Payments are typed in by hand; method + reference are the hook (finance/docs/domain-model.md).')
      )
    }
  }
  DESK = @{
    name = 'Desk'; color = '#a855f7'
    description = 'Shared support inboxes. Plan: desk/docs/plan.md.'
    lists = [ordered]@{
      'MVP follow-ups' = @(
        (T 'Store attachments in S3 instead of Postgres' 'high' 'MVP keeps them as bytea; plan says desk-data bucket + backups.'),
        (T 'Per-mailbox access grants' 'high' 'MVP: tickets.work sees every mailbox.'),
        (T 'Authorization tests against a real Postgres (TEST_DATABASE_URL)' 'high'),
        (T 'Parser tests with real-world .eml fixtures' 'high' 'Outlook, Gmail, Apple Mail, forwarded, bounces, auto-replies, non-UTF-8.'),
        (T 'scripts/smoke-desk.ps1' 'normal' 'Mailbox → mail into GreenMail → conversation → reply in Mailpit → customer answers → same conversation reopens.'),
        (T 'Tags and stars on conversations' 'normal'),
        (T 'Saved replies' 'normal'),
        (T 'Auto-reply with loop protection' 'normal'),
        (T 'Forward, merge and move conversations; trash' 'normal'),
        (T 'Full-text search' 'normal'),
        (T 'Customer profiles with history; merge customers' 'normal'),
        (T 'Notifications for new and assigned conversations' 'normal'),
        (T 'Keyboard shortcuts' 'low'),
        (T 'Desk README and operations notes' 'low')
      )
      'Decisions' = @(
        (T 'Decide which real mailboxes come first and where they are hosted' 'high' 'Microsoft 365 and Gmail may force OAuth2 into the first slice.'),
        (T 'Decide whether Desk deletes/moves fetched mail or only marks it read' 'normal'),
        (T 'Decide retention for closed conversations and raw mail (GDPR)' 'normal'),
        (T 'Decide: mailbox access as HR roles (one group per mailbox) or grants inside Desk' 'normal')
      )
      'Later' = @(
        (T 'OAuth2 mailboxes (Microsoft 365, Gmail)' 'normal'),
        (T 'IMAP IDLE instead of polling' 'low'),
        (T 'Automation rules, SLAs and reporting' 'low'),
        (T 'Customer portal / web contact form' 'low'),
        (T 'Create a task in Tasks from a conversation' 'low')
      )
    }
  }
  TASK = @{
    name = 'Tasks'; color = '#3b82f6'
    description = 'This app. Plan: tasks/docs/plan.md.'
    lists = [ordered]@{
      'MVP follow-ups' = @(
        (T 'Per-space access: grants and private lists' 'high' 'MVP: every signed-in user sees every space.'),
        (T 'Authorization tests against a real Postgres (TEST_DATABASE_URL)' 'high'),
        (T 'Filters, sort and bulk actions in List view' 'normal'),
        (T 'Tags' 'normal'),
        (T 'Comments with @mentions, watchers and an in-app Inbox' 'normal'),
        (T 'Checklists on tasks' 'normal'),
        (T 'Attachments (S3)' 'normal'),
        (T 'Ctrl+K search and task-ID jump' 'normal'),
        (T 'Folders between spaces and lists; drag and drop in the sidebar' 'normal'),
        (T 'Move tasks between spaces with status mapping' 'low' 'MVP only moves within a space.'),
        (T 'Favourites, archive and trash' 'low'),
        (T 'Show version conflicts in the UI (API already rejects stale versions)' 'low'),
        (T 'scripts/smoke-tasks.ps1' 'normal'),
        (T 'Tasks README' 'low')
      )
      'Later' = @(
        (T 'Custom fields' 'high' 'Biggest gap against ClickUp; plan right after the first slice.'),
        (T 'Calendar view' 'normal'),
        (T 'Live updates over SSE instead of polling' 'normal'),
        (T 'Email notifications and due-soon reminders' 'normal'),
        (T 'Dependencies and recurring tasks' 'low'),
        (T 'Gantt / timeline and workload views' 'low'),
        (T 'Time tracking' 'low'),
        (T 'Automations' 'low'),
        (T 'Import from ClickUp, Vikunja or CSV' 'low')
      )
      'Decisions' = @(
        (T 'Decide: new spaces open to the whole organization or closed by default' 'normal' 'Answer the same way for the wiki.'),
        (T 'Decide: one space per HR department automatically, or by hand' 'low'),
        (T 'Decide whether guests (vendors without staff accounts) are needed this year' 'low')
      )
    }
  }
  WIKI = @{
    name = 'Wiki'; color = '#ef4444'
    description = 'Notion-style pages with live editing. Plan: wiki/docs/plan.md.'
    lists = [ordered]@{
      'Milestones' = @(
        (T 'Scaffold: copy Learn, add S3, wire compose/Keycloak/proxy/HR/Den' 'high' 'Done when it signs in, pairs with Den and shows in HR''s access picker.'),
        (T 'Spaces, page tree and access (with authorization tests)' 'high'),
        (T 'Live editing: Yjs relay in Go (own framing, ADR 0001), disk buffer, compaction to S3, BlockNote' 'high' 'Two browsers edit at once; restart mid-edit loses nothing.'),
        (T 'Files: image and file blocks through the backend' 'normal'),
        (T 'History and trash: revisions, preview, restore' 'normal'),
        (T 'Search, @mentions, backlinks and favourites' 'normal'),
        (T 'scripts/smoke-wiki.ps1, READMEs and operations notes' 'normal')
      )
      'Later' = @(
        (T 'Notion-style databases (table/board/calendar of pages)' 'normal'),
        (T 'Comments and inline discussions' 'normal'),
        (T 'Public share links' 'low'),
        (T 'Templates, Markdown import and export' 'low')
      )
      'Decisions' = @(
        (T 'Decide: new team spaces open to the organization or closed' 'normal'),
        (T 'Decide what happens to a private space when someone is offboarded' 'normal'),
        (T 'Decide whether offline editing is needed' 'low')
      )
    }
  }
}

# Findings from code review: MODULE | LIST | TITLE | PRIORITY | EVIDENCE
$moduleKeys = @{ platform = 'OPS'; den = 'DEN'; hr = 'HR'; stash = 'STASH'; events = 'EVT'; learn = 'LRN'; finance = 'FIN'; desk = 'DESK'; tasks = 'TASK'; wiki = 'WIKI' }
$listNames = @{ 'Unfinished' = 'Unfinished & stubs' }
$findings = Join-Path $PSScriptRoot 'data\tasks-backlog.txt'
if (Test-Path $findings) {
  foreach ($line in Get-Content -Encoding UTF8 $findings) {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    $f = $line -split '\s\|\s', 5
    if ($f.Count -ne 5) { Write-Warning "skipped: $line"; continue }
    $key = $moduleKeys[$f[0].Trim()]
    if (-not $key) { Write-Warning "unknown module: $($f[0])"; continue }
    $list = $f[1].Trim()
    if ($listNames.ContainsKey($list)) { $list = $listNames[$list] }
    $lists = $backlog[$key].lists
    if (-not $lists.Contains($list)) { $lists[$list] = @() }
    $lists[$list] += , (T $f[2].Trim() $f[3].Trim() "Found in code review: $($f[4].Trim())")
  }
}

$spaces = Api GET '/spaces'
$spaces = $spaces.spaces
$created = 0
foreach ($key in $backlog.Keys) {
  $def = $backlog[$key]
  $space = $spaces | Where-Object key -eq $key
  if (-not $space) {
    $space = Api POST '/spaces' @{ name = $def.name; key = $key; color = $def.color; description = $def.description }
    Write-Host "space $key created"
  }
  $first = $true
  foreach ($listName in $def.lists.Keys) {
    $list = $space.lists | Where-Object name -eq $listName
    if (-not $list) {
      $general = $space.lists | Where-Object name -eq 'General'
      if ($first -and $general -and $general.open_tasks -eq 0 -and $general.done_tasks -eq 0) {
        $list = Api PATCH "/lists/$($general.id)" @{ name = $listName }
      } else {
        $list = Api POST "/spaces/$($space.id)/lists" @{ name = $listName }
      }
      $space = Api GET "/spaces/$($space.id)"
    }
    $first = $false
    $existing = (Api GET "/lists/$($list.id)/tasks").tasks.title
    foreach ($t in $def.lists[$listName]) {
      if ($existing -contains $t.title) { continue }
      $body = @{ list_id = $list.id; title = $t.title; description = $t.description }
      if ($t.priority) { $body.priority = $t.priority }
      Api POST '/tasks' $body | Out-Null
      $created++
    }
  }
}
Write-Host "done: $created tasks created"
