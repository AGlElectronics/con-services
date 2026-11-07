<#
.SYNOPSIS
  Manage the Con Services workspace: the con-services repository plus the
  module and GitOps repositories that live inside it as ignored folders.

.DESCRIPTION
  clone   Clone every repository that is missing.
  status  Show branch, uncommitted changes and ahead/behind for each one.
  pull    Fetch and fast-forward every clean repository on its branch.

.EXAMPLE
  ./scripts/workspace.ps1 clone
  ./scripts/workspace.ps1 status
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('clone', 'status', 'pull')]
  [string]$Command = 'status'
)

# Continue: git writes progress and hints to stderr, which Windows
# PowerShell would otherwise turn into terminating errors.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$org = 'https://github.com/AGlElectronics'

# Folder name = repository name. Keep in sync with scripts/workspace.sh and
# the ignore list in .gitignore.
$repos = @('den', 'hr', 'Rally', 'stash', 'finance', 'wiki', 'desk', 'learn', 'tasks', 'con-services-gitops')

function Get-State([string]$path) {
  Push-Location $path
  try {
    $branch = git branch --show-current
    $dirty = (git status --porcelain | Measure-Object).Count
    $hasUpstream = git for-each-ref --format='%(upstream:short)' "refs/heads/$branch"
    $ahead, $behind = '-', '-'
    if ($hasUpstream) {
      $ahead, $behind = (git rev-list --left-right --count 'HEAD...@{upstream}') -split '\s+'
    }
    [pscustomobject]@{ Branch = $branch; Dirty = $dirty; Ahead = $ahead; Behind = $behind }
  } finally { Pop-Location }
}

switch ($Command) {
  'clone' {
    foreach ($r in $repos) {
      $path = Join-Path $root $r
      if (Test-Path (Join-Path $path '.git')) { Write-Host "ok      $r"; continue }
      git clone "$org/$r.git" $path
      if ($LASTEXITCODE -ne 0) { Write-Warning "could not clone $r (no access?)" }
    }
  }
  'status' {
    $rows = foreach ($r in @('.') + $repos) {
      $path = Join-Path $root $r
      if (-not (Test-Path (Join-Path $path '.git'))) {
        [pscustomobject]@{ Repo = $r; Branch = '(missing)'; Dirty = ''; Ahead = ''; Behind = '' }
        continue
      }
      $s = Get-State $path
      [pscustomobject]@{ Repo = $(if ($r -eq '.') { 'con-services' } else { $r }); Branch = $s.Branch; Dirty = $s.Dirty; Ahead = $s.Ahead; Behind = $s.Behind }
    }
    $rows | Format-Table -AutoSize
  }
  'pull' {
    foreach ($r in @('.') + $repos) {
      $path = Join-Path $root $r
      $name = if ($r -eq '.') { 'con-services' } else { $r }
      if (-not (Test-Path (Join-Path $path '.git'))) { Write-Host "missing $name"; continue }
      if ((Get-State $path).Dirty -gt 0) { Write-Host "skip    $name (uncommitted changes)"; continue }
      git -C $path pull --ff-only --quiet
      if ($LASTEXITCODE -eq 0) { Write-Host "pulled  $name" } else { Write-Warning "could not fast-forward $name" }
    }
  }
}
