# Static checks for migration 002 (no live Postgres required).
# Usage (from Database/):  powershell -File tests/static_verify_002.ps1
$ErrorActionPreference = "Stop"
$mig = (Resolve-Path (Join-Path $PSScriptRoot "..\migrations\002_post_consultation_fixes.sql")).Path
$one = (Resolve-Path (Join-Path $PSScriptRoot "..\migrations\001_initial_schema.sql")).Path
$schemaMd = (Resolve-Path (Join-Path $PSScriptRoot "..\SCHEMA.md")).Path

$sql = Get-Content -Raw $mig
$md = Get-Content -Raw $schemaMd
$oneSql = Get-Content -Raw $one

$checks = @(
  @{ Name = "001 untouched marker still present"; Ok = $oneSql -match "CREATE TABLE IF NOT EXISTS public.profiles" },
  @{ Name = "002 does not DROP TABLE"; Ok = $sql -notmatch "(?i)DROP\s+TABLE" },
  @{ Name = "document_type CHECK"; Ok = $sql -match "prescription" -and $sql -match "lab_result" -and $sql -match "medical_letter" },
  @{ Name = "upload metadata columns"; Ok = $sql -match "uploaded_by" -and $sql -match "mime_type" -and $sql -match "size_bytes" },
  @{ Name = "mime CHECK"; Ok = $sql -match "application/pdf" -and $sql -match "image/png" -and $sql -match "image/jpeg" },
  @{ Name = "size_bytes >= 0"; Ok = $sql -match "size_bytes IS NULL OR size_bytes >= 0" },
  @{ Name = "ai status CHECK"; Ok = $sql -match "'pending'" -and $sql -match "'completed'" -and $sql -match "'failed'" },
  @{ Name = "urgency vocabulary"; Ok = $sql -match "routine" -and $sql -match "review_required" -and $sql -match "potential_emergency" },
  @{ Name = "search_path fixed"; Ok = $sql -match "SET search_path = ''" },
  @{ Name = "conversation columns"; Ok = $sql -match "context_relevance" -and $sql -match "patient_guidance" -and $sql -match "doctor_draft" -and $sql -match "summarized_until_message_id" },
  @{ Name = "SCHEMA documents MIME"; Ok = $md -match "application/pdf" },
  @{ Name = "SCHEMA documents authz backend"; Ok = $md -match "bypasses RLS" -or $md -match "bypass RLS" },
  @{ Name = "SCHEMA urgency limitation"; Ok = $md -match "not.*diagnostic" -or $md -match "nu.*diagnostic" }
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
Write-Host "Live DB checks were NOT run. After applying 002 in Supabase, run migrations/verify_002_checks.sql"
