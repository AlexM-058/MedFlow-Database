# Static checks for migration 003 (no live Postgres required).
# Usage (from Database/):  powershell -File tests/static_verify_003.ps1
$ErrorActionPreference = "Stop"
$mig = (Resolve-Path (Join-Path $PSScriptRoot "..\migrations\003_doctor_orchestration_state.sql")).Path
$two = (Resolve-Path (Join-Path $PSScriptRoot "..\migrations\002_post_consultation_fixes.sql")).Path
$schemaMd = (Resolve-Path (Join-Path $PSScriptRoot "..\SCHEMA.md")).Path

$sql = Get-Content -Raw $mig
$md = Get-Content -Raw $schemaMd
$twoSql = Get-Content -Raw $two

$checks = @(
  @{ Name = "002 untouched marker still present"; Ok = $twoSql -match "FIX 5" },
  @{ Name = "003 does not DROP"; Ok = $sql -notmatch "(?i)\bDROP\b" },
  @{ Name = "003 wrapped in a transaction"; Ok = $sql -match "BEGIN;" -and $sql -match "COMMIT;" },
  @{ Name = "column added to cases as JSONB"; Ok = $sql -match "ALTER TABLE public\.cases\s+ADD COLUMN IF NOT EXISTS doctor_orchestration_state JSONB" },
  @{ Name = "column is nullable (no NOT NULL)"; Ok = $sql -notmatch "doctor_orchestration_state JSONB NOT NULL" },
  @{ Name = "object-only CHECK"; Ok = $sql -match "jsonb_typeof\(doctor_orchestration_state\) = 'object'" },
  @{ Name = "CHECK is re-runnable"; Ok = $sql -match "WHEN duplicate_object THEN NULL" },
  @{ Name = "SCHEMA lists migration 003"; Ok = $md -match "003_doctor_orchestration_state\.sql" },
  @{ Name = "SCHEMA documents the column"; Ok = $md -match "doctor_orchestration_state" }
)

$failed = 0
foreach ($c in $checks) {
  if ($c.Ok) { Write-Host "PASS  $($c.Name)" }
  else { Write-Host "FAIL  $($c.Name)"; $failed++ }
}

if ($failed -gt 0) {
  Write-Host "`n$failed check(s) failed."
  exit 1
}
Write-Host "`nAll $($checks.Count) static checks passed."
Write-Host "Live DB checks were NOT run. After applying 003 in Supabase, run migrations/verify_003_checks.sql"
