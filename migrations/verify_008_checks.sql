-- Manual verification for migration 008 (Supabase SQL Editor, AFTER applying 008).
-- Read-only: only inspects the catalog. Raises an exception if something is missing.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'medical_documents'
      AND column_name = 'review' AND data_type = 'jsonb' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'missing nullable jsonb column medical_documents.review';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'medical_documents'
      AND column_name = 'reviewed_by' AND data_type = 'uuid' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'missing nullable uuid column medical_documents.reviewed_by';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'medical_documents'
      AND column_name = 'reviewed_at' AND data_type = 'timestamp with time zone' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'missing nullable timestamptz column medical_documents.reviewed_at';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_documents_review_object_check'
  ) THEN
    RAISE EXCEPTION 'missing medical_documents_review_object_check';
  END IF;

  RAISE NOTICE 'migration 008 OK';
END $$;
