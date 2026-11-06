-- Manual verification for migration 002 (Supabase SQL Editor, AFTER applying 002).
-- Ends with ROLLBACK — does not keep probe data.
-- Does not delete existing medical rows.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_documents_document_type_check'
  ) THEN
    RAISE EXCEPTION 'missing medical_documents_document_type_check';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_documents_mime_type_check'
  ) THEN
    RAISE EXCEPTION 'missing medical_documents_mime_type_check';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_documents_size_bytes_check'
  ) THEN
    RAISE EXCEPTION 'missing medical_documents_size_bytes_check';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ai_analyses_status_check'
  ) THEN
    RAISE EXCEPTION 'missing ai_analyses_status_check';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ai_analyses_urgency_check'
  ) THEN
    RAISE EXCEPTION 'missing ai_analyses_urgency_check';
  END IF;

  IF (
    SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'medical_documents'
      AND column_name IN ('uploaded_by', 'mime_type', 'size_bytes')
  ) <> 3 THEN
    RAISE EXCEPTION 'medical_documents upload metadata columns missing';
  END IF;

  IF (
    SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'ai_analyses'
      AND column_name IN (
        'context_relevance', 'patient_guidance', 'doctor_draft',
        'summarized_until_message_id'
      )
  ) <> 4 THEN
    RAISE EXCEPTION 'ai_analyses conversation columns missing';
  END IF;
END $$;

-- search_path present on function definition
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'set_cases_updated_at';

  IF def IS NULL OR position('search_path' IN lower(def)) = 0 THEN
    RAISE EXCEPTION 'set_cases_updated_at missing search_path setting';
  END IF;
END $$;

-- 001 compatibility: core tables still exist
DO $$
BEGIN
  IF to_regclass('public.cases') IS NULL
     OR to_regclass('public.medical_documents') IS NULL
     OR to_regclass('public.ai_analyses') IS NULL THEN
    RAISE EXCEPTION '001 core tables missing — incompatible state';
  END IF;
END $$;

ROLLBACK;

SELECT 'verify_002_checks: structural assertions OK (rolled back)' AS result;
