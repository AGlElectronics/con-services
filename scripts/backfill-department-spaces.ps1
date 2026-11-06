# Backfills one Tasks space per existing HR department (TASK-25).
#
# HR only calls the Tasks hook when a department is created or renamed, so
# departments that existed before the hook was wired need this one-time
# push. Safe to re-run: the endpoint is idempotent (it updates the name and
# otherwise leaves the space alone).
#
# Usage (dev copy):   .\scripts\backfill-department-spaces.ps1
# Usage (live, at cutover):
#   .\scripts\backfill-department-spaces.ps1 -Url http://localhost:8160/api/internal/departments -Token <live token>
param(
    [string]$Url = 'http://localhost:8161/api/internal/departments',
    [string]$Token = 'tasks-service-dev-token'
)

$ErrorActionPreference = 'Stop'

$rows = docker exec conservices-postgres psql -U hr -d hr -A -t -F "`t" -c `
    "select id, slug, name, group_name from departments order by name"
if ($LASTEXITCODE -ne 0) { throw 'could not read departments from the hr database' }

$count = 0
foreach ($row in $rows) {
    if (-not $row) { continue }
    $p = $row -split "`t"
    $body = @{ id = $p[0]; slug = $p[1]; name = $p[2]; group = $p[3] } | ConvertTo-Json
    $res = Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $Token" } -Body $body
    Write-Host "$($p[1]) -> space $($res.key) ($($res.name))"
    $count++
}
Write-Host "$count department(s) synced."
