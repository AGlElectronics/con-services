# Idempotent: create Desk IMAP mailboxes for the durable GreenMail accounts
# (support@ and info@). Leaves registration@ alone for smoke-desk.ps1.
#
# Needs the desk profile running (GreenMail + Desk). Sign-in as desk-admin.
#
# Usage: powershell -File scripts/seed-desk-mailboxes.ps1
#        powershell -File scripts/seed-desk-mailboxes.ps1 -Base http://localhost:8150
#        powershell -File scripts/seed-desk-mailboxes.ps1 -Domain desk.test   # standalone stack
# (PowerShell 7: pwsh -File … works the same.)
param(
  [string]$Base = 'http://localhost:3008',
  [string]$Keycloak = 'http://localhost:8085',
  [string]$User = 'admin',
  [string]$Password = 'adminadmin',
  [string]$Domain = 'conservices.test',
  [string]$ImapHost = 'greenmail',
  [int]$ImapPort = 3143
)
$ErrorActionPreference = 'Stop'
$api = "$Base/api/v1"

$token = (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/conservices/protocol/openid-connect/token" -Body @{
  grant_type = 'password'; client_id = 'desk-spa'; username = $User; password = $Password; scope = 'openid'
}).access_token
$h = @{ Authorization = "Bearer $token" }

function Api($method, $path, $body) {
  $req = @{ Method = $method; Uri = "$api$path"; Headers = $h }
  if ($null -ne $body) {
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  }
  Invoke-RestMethod @req
}

$existing = @((Api GET '/mailboxes').mailboxes)
$byEmail = @{}
foreach ($m in $existing) { $byEmail[$m.email.ToLowerInvariant()] = $m }

$boxes = @(
  @{ name = 'Support'; slug = 'support'; local = 'support' },
  @{ name = 'Info'; slug = 'info'; local = 'info' }
)

foreach ($b in $boxes) {
  $email = "$($b.local)@$Domain"
  $key = $email.ToLowerInvariant()
  if ($byEmail.ContainsKey($key)) {
    Write-Host "keep  $email (id $($byEmail[$key].id))"
    continue
  }
  $created = Api POST '/mailboxes' @{
    name = $b.name; email = $email; slug = $b.slug; connector = 'imap'
    imap_host = $ImapHost; imap_port = $ImapPort; imap_security = 'none'
    imap_username = $email; imap_password = $b.local
  }
  Write-Host "create $email (id $($created.id))"
  $test = Api POST "/mailboxes/$($created.id)/test" @{}
  if (-not $test.imap_ok) { throw "IMAP failed for $email`: $($test.imap_error)" }
  Write-Host "  IMAP ok; SMTP via $($test.smtp_via) (ok=$($test.smtp_ok))"
}

Write-Host ''
Write-Host 'Seeded. Send a fake customer mail with:'
Write-Host '  powershell -File scripts/send-desk-test-mail.ps1'
Write-Host "  powershell -File scripts/send-desk-test-mail.ps1 -To info@$Domain"
