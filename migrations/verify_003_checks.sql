-- Manual verification for migration 003 (Supabase SQL Editor, AFTER applying 003).
-- Ends with ROLLBACK — does not keep probe data.
-- Does not delete existing medical rows.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'cases'
      AND column_name = 'doctor_orchestration_state'
      AND data_type = 'jsonb'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'missing nullable jsonb column cases.doctor_orchestration_state';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'cases_doctor_orchestration_state_object_check'
  ) THEN
    RAISE EXCEPTION 'missing cases_doctor_orchestration_state_object_check';
  END IF;
END $$;

-- 002 compatibility: earlier migration objects still exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ai_analyses_status_check'
  ) THEN
    RAISE EXCEPTION '002 not applied — apply 002 before 003';
  END IF;
END $$;

ROLLBACK;

SELECT 'verify_003_checks: structural assertions OK (rolled back)' AS result;
