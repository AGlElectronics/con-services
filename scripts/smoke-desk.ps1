# Smoke: Desk end to end against the running dev stack
# (docker compose --profile desk up). Creates a throwaway IMAP mailbox on
# GreenMail as admin, sends a customer mail into it over SMTP, waits for the
# conversation, answers it (Mailpit receives the reply), checks undo, a note,
# the conversation trash and that a user without the mailbox's roles gets 404.
# Moves the mailbox to the trash and purges it afterwards.
#
# The mailbox must not exist in Desk yet. GreenMail only lets its configured
# users log in (support@ and registration@conservices.test); registration@
# is used so the dev mailbox support@ is left alone.
#
# Usage: scripts/smoke-desk.ps1                                   # :3008
#        scripts/smoke-desk.ps1 -Base http://localhost:8150       # backend directly
param(
  [string]$Base = 'http://localhost:3008',
  [string]$Keycloak = 'http://localhost:8085',
  [string]$User = 'admin',
  [string]$Password = 'adminadmin',
  [string]$Outsider = 'bob',
  [string]$OutsiderPassword = 'bobbob',
  [string]$MailboxEmail = 'registration@conservices.test',
  [string]$MailboxPassword = 'registration',
  [string]$SmtpHost = 'localhost',
  [int]$SmtpPort = 3025,
  [int]$TimeoutSeconds = 90
)
$ErrorActionPreference = 'Stop'
$api = "$Base/api/v1"

function Get-Token($username, $secret) {
  (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/conservices/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'desk-spa'; username = $username; password = $secret; scope = 'openid'
  }).access_token
}
$h = @{ Authorization = "Bearer $(Get-Token $User $Password)" }
$outsiderHeaders = @{ Authorization = "Bearer $(Get-Token $Outsider $OutsiderPassword)" }

$script:step = 0
function Step($name) { $script:step++; Write-Host ("{0,2}. {1}" -f $script:step, $name) }
function Api($method, $path, $body, $headers = $h) {
  $req = @{ Method = $method; Uri = "$api$path"; Headers = $headers }
  if ($null -ne $body) {
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  }
  Invoke-RestMethod @req
}
function Expect-Status($expected, $method, $path, $body, $what, $headers = $h) {
  try {
    Api $method $path $body $headers | Out-Null
    throw 'EXPECTED-FAIL'
  } catch {
    if ($_.Exception.Message -eq 'EXPECTED-FAIL') { throw "$what succeeded but should have returned $expected" }
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -ne $expected) { throw "$what returned $status, expected $expected" }
  }
}
function Assert($cond, $what) { if (-not $cond) { throw "FAILED: $what" } }
function Wait-Until($what, [scriptblock]$probe) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $result = & $probe
    if ($result) { return $result }
    Start-Sleep -Seconds 2
  }
  throw "FAILED: timed out after $TimeoutSeconds s waiting for $what"
}

$marker = 'smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$mailbox = $null
try {
  Step 'health'
  Invoke-RestMethod -Uri "$Base/api/health" | Out-Null

  Step "create an IMAP mailbox for $MailboxEmail on GreenMail"
  $mailbox = Api POST '/mailboxes' @{
    name = 'Smoke mailbox'; email = $MailboxEmail; slug = 'smoke-desk'; connector = 'imap'
    imap_host = 'greenmail'; imap_port = 3143; imap_security = 'none'
    imap_username = $MailboxEmail; imap_password = $MailboxPassword
  }
  Assert ($mailbox.imap_password_set) 'password stored'
  Assert (@($mailbox.roles | Where-Object group -eq 'desk-smoke-desk-manager').Count -eq 1) 'roles named after the slug'

  Step 'connection test logs in over IMAP and SMTP'
  $test = Api POST "/mailboxes/$($mailbox.id)/test" @{}
  Assert $test.imap_ok "IMAP login works ($($test.imap_error))"
  Assert $test.smtp_ok "SMTP works ($($test.smtp_error))"

  Step 'a customer mail arrives as a conversation'
  $smtp = New-Object Net.Mail.SmtpClient($SmtpHost, $SmtpPort)
  $msg = New-Object Net.Mail.MailMessage("guest-$marker@example.com", $MailboxEmail, "Lost badge $marker", "Hi, I lost my badge. ($marker)")
  $smtp.Send($msg)
  $msg.Dispose()
  Api POST "/mailboxes/$($mailbox.id)/fetch" @{} | Out-Null
  $conv = Wait-Until 'the conversation' {
    @((Api GET "/conversations?mailbox=$($mailbox.id)&folder=all&q=$marker").conversations) | Select-Object -First 1
  }
  Assert ($conv.customer.email -eq "guest-$marker@example.com") 'customer found by address'
  $detail = Api GET "/conversations/$($conv.id)"
  Assert ($detail.threads[0].kind -eq 'customer') 'first thread is the customer message'

  Step 'a reply can be undone within its 10 seconds'
  $undo = Api POST "/conversations/$($conv.id)/threads" @{ kind = 'reply'; body = 'this one is taken back' }
  Api POST "/threads/$($undo.id)/undo" @{} | Out-Null

  Step 'reply goes out, an internal note stays inside'
  $reply = Api POST "/conversations/$($conv.id)/threads" @{ kind = 'reply'; body_html = "<p>We found it ($marker).</p>"; status = 'closed' }
  Api POST "/conversations/$($conv.id)/threads" @{ kind = 'note'; body = 'checked the lost and found box' } | Out-Null
  $sent = Wait-Until 'the reply to be sent' {
    $d = Api GET "/conversations/$($conv.id)"
    $t = @($d.threads | Where-Object id -eq $reply.id) | Select-Object -First 1
    if ($t.send_status -eq 'failed') { throw "FAILED: reply failed: $($t.send_error)" }
    if ($t.send_status -eq 'sent') { $d }
  }
  Assert ($sent.status -eq 'closed') 'status set by the reply'
  Assert (@($sent.threads | Where-Object id -eq $undo.id).Count -eq 0) 'undone reply is gone'
  Assert (@($sent.threads | Where-Object kind -eq 'note').Count -eq 1) 'note stored'

  Step "access per mailbox: $Outsider (no role) gets 404"
  Expect-Status 404 GET "/mailboxes/$($mailbox.id)" $null "$Outsider reading the mailbox" $outsiderHeaders
  Expect-Status 404 GET "/conversations/$($conv.id)" $null "$Outsider reading the conversation" $outsiderHeaders
  $visible = @((Api GET '/mailboxes' $null $outsiderHeaders).mailboxes | Where-Object id -eq $mailbox.id)
  Assert ($visible.Count -eq 0) "mailbox hidden from $Outsider"

  Step 'conversation trash: delete, hidden, restore'
  Api DELETE "/conversations/$($conv.id)" | Out-Null
  $trash = @((Api GET "/conversations?mailbox=$($mailbox.id)&folder=trash").conversations | Where-Object id -eq $conv.id)
  Assert ($trash.Count -eq 1) 'conversation in the trash folder'
  Api POST "/conversations/$($conv.id)/restore" @{} | Out-Null

  Write-Host "`nSMOKE OK ($script:step steps)"
} finally {
  if ($mailbox) {
    try { Api DELETE "/mailboxes/$($mailbox.id)" | Out-Null } catch {}
    try { Api POST "/mailboxes/$($mailbox.id)/purge" @{} | Out-Null } catch { Write-Warning "purge failed: $_" }
  }
}
