-- MedFlow migration 008 — patient review of extracted documents
-- Apply AFTER 007_platform_admins.sql (do not edit earlier migrations).
-- Non-destructive: ADD COLUMN / ADD CONSTRAINT only. Existing rows keep review = NULL.
-- Synthetic / hackathon data only. Do not run against production without review.
--
-- Why: the extraction service reads a prescription from a photo and can misread it. The patient
-- compares every row with the paper prescription and confirms, corrects or marks it "not on the
-- prescription". The Backend (src/documentReview.ts) saves that result here.
--
--   extracted_data  unchanged: exactly what the reader extracted (the doctor can see corrections)
--   review          { "fields": [ReviewedField...], "medications": [{name,dose,frequency,duration}] }
--                   NULL = the patient has not reviewed this document yet
--   reviewed_by     the patient who reviewed (profiles.id)
--   reviewed_at     when
--
-- Only medications from a reviewed document feed the "active treatment" summary (src/records.ts).
-- Apply BEFORE deploying the Backend version that selects these columns.

BEGIN;

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS review JSONB;

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS reviewed_by UUID
    REFERENCES public.profiles (id) ON DELETE SET NULL;

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ;

DO $$
BEGIN
  ALTER TABLE public.medical_documents
    ADD CONSTRAINT medical_documents_review_object_check
    CHECK (review IS NULL OR jsonb_typeof(review) = 'object');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN public.medical_documents.review IS
  'Patient review of the extracted data (verbatim values + confirmation). NULL = not reviewed.';

COMMIT;
