<#
.SYNOPSIS
  Copies the shared Go packages (shared/go/<pkg>) into module backends, or
  checks that the copies have not drifted.

.DESCRIPTION
  Every module backend carries a generated copy of each shared package it
  uses in <backend>/internal/<pkg>. This script writes those copies: import
  paths github.com/AGlElectronics/con-services/shared/go/<x> become
  <module path from go.mod>/internal/<x>, and every file starts with

    // Code generated from con-services shared/go/<pkg>; DO NOT EDIT. Run scripts/sync-shared.

  Files with that header that no longer exist in shared/go are removed.
  Files without it are never touched (a module may keep its own extra tests
  in the folder).

  With -Check nothing is written; the script lists every difference and
  exits with code 1 when a copy has drifted.

  Docs: https://aglelectronics.github.io/con-services/concepts/shared-code/

.PARAMETER Modules
  Module folders in the workspace root, for example hr, Rally, learn. Each
  one's backend is <workspace>/<module>/backend.

.PARAMETER BackendDir
  Backend folders (with go.mod) given directly, for example a module
  checkout in CI or a temporary copy.

.PARAMETER Packages
  Packages to copy, for example denlink, groupmatch. Default: the packages
  the backend already has (folders under internal/ with the header).

.PARAMETER Check
  Only compare; exit 1 on drift.

.EXAMPLE
  scripts/sync-shared.ps1 -Modules learn -Packages denlink,groupmatch

.EXAMPLE
  scripts/sync-shared.ps1 -Modules hr,stash,learn -Check
#>
[CmdletBinding()]
param(
  [string[]]$Modules = @(),
  [string[]]$BackendDir = @(),
  [string[]]$Packages = @(),
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Workspace = Split-Path -Parent $PSScriptRoot
$SharedGo = Join-Path $Workspace 'shared/go'
$SharedModulePath = 'github.com/AGlElectronics/con-services/shared/go'
$HeaderMarker = 'Code generated from con-services shared/go/'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Split-List([string[]]$Values) {
  $out = @()
  foreach ($v in $Values) { foreach ($p in ($v -split ',')) { if ($p.Trim()) { $out += $p.Trim() } } }
  return ,$out
}

function Get-ModulePath([string]$Backend) {
  $gomod = Join-Path $Backend 'go.mod'
  if (-not (Test-Path -LiteralPath $gomod)) { throw "No go.mod in $Backend" }
  foreach ($line in [IO.File]::ReadAllLines($gomod)) {
    if ($line -match '^\s*module\s+(\S+)') { return $Matches[1] }
  }
  throw "No module line in $gomod"
}

function Read-Normalized([string]$Path) {
  return ([IO.File]::ReadAllText($Path, $Utf8NoBom)) -replace "`r`n", "`n"
}

function Test-Generated([string]$Path) {
  $first = ''
  $reader = New-Object IO.StreamReader($Path)
  try { $first = $reader.ReadLine() } finally { $reader.Dispose() }
  return ($null -ne $first) -and $first.Contains($HeaderMarker)
}

function Get-SharedPackages {
  return ,@(Get-ChildItem -LiteralPath $SharedGo -Directory | Where-Object {
      @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.go' -File).Count -gt 0
    } | ForEach-Object { $_.Name })
}

function Get-AdoptedPackages([string]$Backend) {
  $internal = Join-Path $Backend 'internal'
  $found = @()
  foreach ($pkg in (Get-SharedPackages)) {
    $dir = Join-Path $internal $pkg
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $gen = @(Get-ChildItem -LiteralPath $dir -Filter '*.go' -File | Where-Object { Test-Generated $_.FullName })
    if ($gen.Count -gt 0) { $found += $pkg }
  }
  return ,$found
}

function Get-Expected([string]$Pkg, [string]$ModulePath) {
  $header = "// ${HeaderMarker}$Pkg; DO NOT EDIT. Run scripts/sync-shared.`n`n"
  $pattern = '"' + [regex]::Escape($SharedModulePath) + '/'
  $replacement = '"' + $ModulePath + '/internal/'
  $files = [ordered]@{}
  foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $SharedGo $Pkg) -Filter '*.go' -File | Sort-Object Name)) {
    $text = Read-Normalized $f.FullName
    $files[$f.Name] = $header + ($text -replace $pattern, $replacement)
  }
  return $files
}

$Modules = Split-List $Modules
$BackendDir = Split-List $BackendDir
$Packages = Split-List $Packages
$known = Get-SharedPackages
foreach ($p in $Packages) {
  if ($known -notcontains $p) { throw "Unknown package '$p'. shared/go has: $($known -join ', ')" }
}

$targets = @()
foreach ($m in $Modules) { $targets += (Join-Path (Join-Path $Workspace $m) 'backend') }
foreach ($b in $BackendDir) { $targets += $b }
if ($targets.Count -eq 0) { throw 'Name at least one module (-Modules hr,learn) or backend folder (-BackendDir path).' }

$drift = 0
foreach ($backend in $targets) {
  $backend = (Resolve-Path -LiteralPath $backend).Path
  $modulePath = Get-ModulePath $backend
  $pkgs = $Packages
  if ($pkgs.Count -eq 0) { $pkgs = Get-AdoptedPackages $backend }
  if ($pkgs.Count -eq 0) {
    if ($Check) { Write-Host "$backend : no shared packages adopted, nothing to check"; continue }
    throw "$backend has no shared packages yet; choose them with -Packages (available: $($known -join ', '))."
  }
  foreach ($pkg in $pkgs) {
    $dir = Join-Path (Join-Path $backend 'internal') $pkg
    $expected = Get-Expected $pkg $modulePath
    $existing = @()
    if (Test-Path -LiteralPath $dir) { $existing = @(Get-ChildItem -LiteralPath $dir -Filter '*.go' -File) }
    foreach ($f in $existing) {
      if ($expected.Contains($f.Name)) { continue }
      if (Test-Generated $f.FullName) {
        if ($Check) { Write-Host "DRIFT  $pkg/$($f.Name): no longer in shared/go (stale copy)"; $drift++ }
        else { Remove-Item -LiteralPath $f.FullName; Write-Host "removed $($f.FullName)" }
      } else {
        Write-Warning "$($f.FullName) is not generated from shared/go; left alone"
      }
    }
    foreach ($name in $expected.Keys) {
      $path = Join-Path $dir $name
      $want = $expected[$name]
      $have = $null
      if (Test-Path -LiteralPath $path) { $have = Read-Normalized $path }
      if ($have -ceq $want) { continue }
      if ($Check) {
        if ($null -eq $have) { Write-Host "DRIFT  $pkg/${name}: missing" }
        elseif (-not (Test-Generated $path)) { Write-Host "DRIFT  $pkg/${name}: exists but is not a generated copy" }
        else { Write-Host "DRIFT  $pkg/${name}: differs from shared/go/$pkg/$name" }
        $drift++
        continue
      }
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
      [IO.File]::WriteAllText($path, $want, $Utf8NoBom)
      Write-Host "wrote   $path"
    }
    if ($Check) { Write-Host "checked $backend internal/$pkg" }
  }
}

if ($Check -and $drift -gt 0) {
  Write-Host ""
  Write-Host "$drift file(s) differ from con-services shared/go. Fix the code in shared/go and run scripts/sync-shared, never edit the copies."
  exit 1
}
if (-not $Check) {
  Write-Host ""
  Write-Host "Done. In each backend run: go mod tidy; go build ./...; go test ./internal/..."
}
