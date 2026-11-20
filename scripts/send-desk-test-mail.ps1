# Send a fake customer email into GreenMail (no real mail leaves the machine).
# Desk picks it up on the next poll, or immediately with -Fetch.
#
# Needs GreenMail on localhost:3025 (desk profile or standalone Desk stack).
# For -Fetch, Desk must already have a mailbox for -To (see seed-desk-mailboxes.ps1).
#
# Usage: powershell -File scripts/send-desk-test-mail.ps1
#        powershell -File scripts/send-desk-test-mail.ps1 -To info@conservices.test -Fetch
#        powershell -File scripts/send-desk-test-mail.ps1 -Subject "Badge lost" -Body "I lost mine."
# (PowerShell 7: pwsh -File … works the same.)
param(
  [string]$To = 'support@conservices.test',
  [string]$From = '',
  [string]$Subject = '',
  [string]$Body = '',
  [string]$SmtpHost = 'localhost',
  [int]$SmtpPort = 3025,
  [switch]$Fetch,
  [string]$Base = 'http://localhost:3008',
  [string]$Keycloak = 'http://localhost:8085',
  [string]$User = 'admin',
  [string]$Password = 'adminadmin'
)
$ErrorActionPreference = 'Stop'

$marker = 'devmail-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $From) { $From = "guest-$marker@example.com" }
if (-not $Subject) { $Subject = "Test message $marker" }
if (-not $Body) { $Body = "Hello from a fake customer. ($marker)`n`nThis never left the local GreenMail server." }

$smtp = New-Object Net.Mail.SmtpClient($SmtpHost, $SmtpPort)
try {
  $msg = New-Object Net.Mail.MailMessage($From, $To, $Subject, $Body)
  try {
    $smtp.Send($msg)
  } finally {
    $msg.Dispose()
  }
} finally {
  $smtp.Dispose()
}
Write-Host "Sent to $To via ${SmtpHost}:${SmtpPort}"
Write-Host "  From:    $From"
Write-Host "  Subject: $Subject"
Write-Host "  Marker:  $marker"

if (-not $Fetch) {
  Write-Host 'Desk will fetch on the next poll, or run again with -Fetch.'
  return
}

$api = "$Base/api/v1"
$token = (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/conservices/protocol/openid-connect/token" -Body @{
  grant_type = 'password'; client_id = 'desk-spa'; username = $User; password = $Password; scope = 'openid'
}).access_token
$h = @{ Authorization = "Bearer $token" }

$mailboxes = @((Invoke-RestMethod -Uri "$api/mailboxes" -Headers $h).mailboxes)
$box = @($mailboxes | Where-Object { $_.email -eq $To }) | Select-Object -First 1
if (-not $box) {
  throw "No Desk mailbox for $To. Run: powershell -File scripts/seed-desk-mailboxes.ps1"
}
Invoke-RestMethod -Method Post -Uri "$api/mailboxes/$($box.id)/fetch" -Headers $h | Out-Null
Write-Host "Fetch requested for mailbox $($box.name) ($($box.id)). Open Desk and search for $marker."
