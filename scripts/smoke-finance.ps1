# Smoke: Finance's money loop end to end against a running backend.
#
# Walks roles, an invoice from draft to a stored PDF, idempotent retries, a
# payment approved by a second person, the rule that paid invoices are never
# voided, a credit note and refund, a closed month, and the audit log.
# Invoices are legal records and are never deleted, so the script leaves a
# customer "Smoke customer <time>" and its invoice behind (dev data only).
#
# Users (dev realm, DEV-ONLY passwords): bob = bookkeeper, alice = approver,
# admin = Finance admin. With -DevAuth the X-Dev-User / X-Dev-Groups headers
# are sent instead (backend with AUTH_MODE=dev).
#
# Usage: scripts/smoke-finance.ps1                                   # root stack (:3006)
#        scripts/smoke-finance.ps1 -Base http://localhost:8130       # backend directly
#        scripts/smoke-finance.ps1 -Base http://localhost:8131 -DevAuth
param(
  [string]$Base = 'http://localhost:3006',
  [string]$Keycloak = 'http://localhost:8085',
  [switch]$DevAuth
)
$ErrorActionPreference = 'Stop'
$api = "$Base/api"

$users = @{
  bob   = @{ password = 'bobbob'; groups = 'finance_bookkeeper' }
  alice = @{ password = 'alicealice'; groups = 'finance_approver' }
  admin = @{ password = 'adminadmin'; groups = 'finance_admin' }
}
$headers = @{}
foreach ($u in $users.Keys) {
  if ($DevAuth) {
    $headers[$u] = @{ 'X-Dev-User' = $u; 'X-Dev-Groups' = $users[$u].groups }
  } else {
    # Finance checks the ID token (audience finance-spa), not the access token.
    $tok = (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/conservices/protocol/openid-connect/token" -Body @{
        grant_type = 'password'; client_id = 'finance-spa'; username = $u; password = $users[$u].password; scope = 'openid'
      }).id_token
    $headers[$u] = @{ Authorization = "Bearer $tok" }
  }
}

$script:step = 0
function Step($name) { $script:step++; Write-Host ("{0,2}. {1}" -f $script:step, $name) }
function Assert($cond, $what) { if (-not $cond) { throw "FAILED: $what" } }

# Call returns @{ Status; Body; Headers; Raw } and never throws on HTTP errors.
function Call($who, $method, $path, $body, [hashtable]$extra = @{}) {
  $h = @{} + $headers[$who] + $extra
  $req = @{ Method = $method; Uri = "$api$path"; Headers = $h; UseBasicParsing = $true }
  if ($null -ne $body) {
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
  }
  try {
    $res = Invoke-WebRequest @req
    $status = [int]$res.StatusCode; $content = $res.Content; $hdrs = $res.Headers
  } catch {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { throw }
    $status = [int]$resp.StatusCode; $hdrs = @{}
    $content = $_.ErrorDetails.Message
    if (-not $content) {
      $reader = New-Object IO.StreamReader($resp.GetResponseStream())
      $content = $reader.ReadToEnd()
    }
  }
  $parsed = $null
  if ($content -and $content -is [string] -and $content.TrimStart().StartsWith('{')) { $parsed = $content | ConvertFrom-Json }
  @{ Status = $status; Body = $parsed; Headers = $hdrs; Raw = $content }
}
function Expect($res, [int[]]$codes, $what) {
  if ($codes -notcontains $res.Status) { throw "$what returned $($res.Status), expected $($codes -join ' or '): $($res.Raw)" }
  $res
}
# Approves a 202 answer as alice (after checking bob cannot) and returns the result id.
function Settle($res, $what) {
  if ($res.Status -ne 202) { return $null }
  $id = $res.Body.approval.id
  Expect (Call bob POST "/approvals/$id/approve" @{}) 403 "$what approved by its requester" | Out-Null
  $a = (Expect (Call alice POST "/approvals/$id/approve" @{ note = 'smoke' }) 200 "$what approved by alice").Body
  Assert ($a.status -eq 'approved' -and $a.result_id) "$what approval carried out"
  $a.result_id
}
function Key() { [guid]::NewGuid().ToString() }

$closedMonth = $null
try {
  Step 'health and roles'
  Invoke-RestMethod -Uri "$Base/readyz" | Out-Null
  foreach ($u in 'bob', 'alice', 'admin') {
    $me = (Expect (Call $u GET '/me') 200 "me as $u").Body
    Assert $me.has_access "$u has Finance access (groups: $($me.groups -join ','))"
  }
  Expect (Call alice POST '/customers' @{ name = 'nope' }) 403 'approver creating a customer' | Out-Null
  Expect (Call bob GET '/audit') 403 'bookkeeper reading the audit log' | Out-Null
  $catalog = Invoke-RestMethod -Uri "$api/role-catalog"
  Assert ($catalog.roles.Count -eq 4) 'role catalog publishes four roles'

  Step 'seller details are set (admin sets them when empty)'
  $s = (Expect (Call admin GET '/settings') 200 'settings').Body
  if (-not $s.seller.name -or -not $s.seller.address) {
    $s = (Expect (Call admin PUT '/settings' @{ seller_name = 'Smoke Con e.V.'; seller_address = "Main Street 1`n12345 Town" }) 200 'set seller').Body
  }
  Assert $s.storage_configured 'S3 storage is configured'
  $threshold = [int64]$s.approval_threshold_cents

  Step 'customer and draft, with an idempotent retry'
  $cust = (Expect (Call bob POST '/customers' @{ name = "Smoke customer $(Get-Date -Format s)"; billing_address = 'Hotelweg 5'; tax_id = 'ATU1234' }) 201 'create customer').Body
  $draftBody = @{ customer_id = $cust.id; notes = 'smoke'; lines = @(@{ description = 'Hall rental'; quantity = 1; unit_price_cents = 10000; tax_rate_bp = 2100 }) }
  Expect (Call bob POST '/invoices' $draftBody) 400 'create without Idempotency-Key' | Out-Null
  $k = Key
  $inv = (Expect (Call bob POST '/invoices' $draftBody @{ 'Idempotency-Key' = $k }) 201 'create draft').Body
  $again = Expect (Call bob POST '/invoices' $draftBody @{ 'Idempotency-Key' = $k }) 201 'retry create draft'
  Assert ($again.Body.id -eq $inv.id) 'retry returns the same draft'
  Expect (Call bob POST '/invoices' @{ customer_id = $cust.id; notes = 'other'; lines = $draftBody.lines } @{ 'Idempotency-Key' = $k }) 422 'reused key, other body' | Out-Null
  Expect (Call bob POST '/invoices' @{ customer_id = $cust.id; notes = ''; lines = @(@{ description = 'neg'; quantity = 1; unit_price_cents = -1; tax_rate_bp = 0 }) } @{ 'Idempotency-Key' = (Key) }) 422 'negative unit price' | Out-Null

  Step 'issue: number, frozen details, stored PDF'
  $inv = (Expect (Call bob POST "/invoices/$($inv.id)/issue" @{}) 200 'issue').Body
  Assert ($inv.number -and $inv.status -eq 'issued' -and $inv.has_pdf -and $inv.seller.name) "issued with number, seller and PDF ($($inv.number))"
  $pdf = Invoke-WebRequest -Uri "$api/invoices/$($inv.id)/pdf" -Headers $headers['alice'] -UseBasicParsing
  $bytes = if ($pdf.Content -is [byte[]]) { $pdf.Content } else { [Text.Encoding]::ASCII.GetBytes($pdf.Content) }
  Assert ([Text.Encoding]::ASCII.GetString($bytes, 0, 5) -eq '%PDF-') 'the PDF downloads'
  Expect (Call bob PATCH "/invoices/$($inv.id)" $draftBody) 409 'editing an issued invoice' | Out-Null

  Step 'payment, approved by a second person'
  $pay = @{ amount_cents = $inv.total_cents; method = 'bank_transfer'; reference = 'SMOKE' }
  $res = Expect (Call bob POST "/invoices/$($inv.id)/payments" $pay @{ 'Idempotency-Key' = (Key) }) 201, 202 'record payment'
  if ($inv.total_cents -gt $threshold) { Assert ($res.Status -eq 202) 'payment above the threshold waits for approval' }
  Settle $res 'payment' | Out-Null
  $inv = (Expect (Call bob GET "/invoices/$($inv.id)") 200 'get invoice').Body
  Assert ($inv.status -eq 'paid') "invoice is paid (status $($inv.status))"

  Step 'paid invoices are never voided'
  Expect (Call bob POST "/invoices/$($inv.id)/void" @{ reason = 'smoke' }) 409 'void a paid invoice' | Out-Null

  Step 'credit note and refund'
  $cnRes = Expect (Call bob POST "/invoices/$($inv.id)/credit-notes" @{ reason = 'Smoke correction'; lines = @(@{ description = 'Discount'; quantity = 1; unit_price_cents = 2000; tax_rate_bp = 2100 }) } @{ 'Idempotency-Key' = (Key) }) 201, 202 'credit note'
  $cnId = Settle $cnRes 'credit note'
  if (-not $cnId) { $cnId = $cnRes.Body.id }
  $cn = (Expect (Call alice GET "/credit-notes/$cnId") 200 'get credit note').Body
  Assert ($cn.number -like '*CN*' -and $cn.total_cents -eq 2420) "credit note $($cn.number) for 24.20"
  $rRes = Expect (Call bob POST "/credit-notes/$cnId/refunds" @{ amount_cents = 2420; method = 'bank_transfer'; reference = 'SMOKE-REFUND' } @{ 'Idempotency-Key' = (Key) }) 201, 202 'refund'
  Settle $rRes 'refund' | Out-Null
  $inv = (Expect (Call bob GET "/invoices/$($inv.id)") 200 'get invoice').Body
  Assert ($inv.credited_cents -eq 2420 -and $inv.refunded_cents -eq 2420 -and $inv.refundable_cents -eq 0) 'credited and refunded'
  $ledger = (Expect (Call alice GET '/ledger?limit=200') 200 'ledger').Body
  Assert (@($ledger.entries | Where-Object { $_.kind -eq 'refund' -and $_.detail -eq $cn.number }).Count -eq 1) 'refund is in the ledger'

  Step 'closed month refuses changes; only an admin reopens'
  $month = (Get-Date).AddMonths(-2).ToString('yyyy-MM')
  $close = Expect (Call alice POST "/periods/$month/close") 201, 409 "close $month"
  if ($close.Status -eq 201) { $closedMonth = $month }
  $exp = @{ vendor = 'Smoke vendor'; amount_cents = 100; occurred_on = "$month-15" }
  $blocked = Expect (Call bob POST '/expenses' $exp @{ 'Idempotency-Key' = (Key) }) 409 'expense in a closed month'
  Assert ($blocked.Body.error.code -eq 'period_closed') 'answer is period_closed'
  if ($closedMonth) {
    Expect (Call alice POST "/periods/$month/reopen" @{ reason = 'smoke' }) 403 'approver reopening' | Out-Null
    Expect (Call admin POST "/periods/$month/reopen" @{ reason = 'smoke test' }) 204 'admin reopening' | Out-Null
    $closedMonth = $null
  }

  Step 'audit log shows who did what'
  $log = (Expect (Call alice GET "/audit?entity_id=$($inv.id)&limit=50") 200 'audit').Body
  $actions = @($log.events | ForEach-Object { $_.action })
  foreach ($a in 'invoice.created', 'invoice.issued', 'payment.recorded') {
    Assert ($actions -contains $a) "audit has $a (has: $($actions -join ', '))"
  }
  Assert (@($log.events | Where-Object { $_.action -eq 'invoice.issued' -and $_.actor.name }).Count -eq 1) 'issue event names the actor'

  Write-Host "OK: Finance smoke passed ($($inv.number), $($cn.number))" -ForegroundColor Green
} finally {
  if ($closedMonth) { Call admin POST "/periods/$closedMonth/reopen" @{ reason = 'smoke cleanup' } | Out-Null }
}
