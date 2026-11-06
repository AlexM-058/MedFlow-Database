-- MedFlow migration 002 — post-consultation schema review fixes
-- Apply AFTER 001_initial_schema.sql (do not edit 001).
-- Non-destructive: ALTER / ADD CONSTRAINT / CREATE OR REPLACE only.
-- Synthetic / hackathon data only. Do not run against production without review.
--
-- Backend note (current repo): MedFlow-Backend is Node.js + Express and uses the
-- Supabase service_role key. Privileged access bypasses RLS — authorization must
-- be enforced in application code for every request.

BEGIN;

-- ---------------------------------------------------------------------------
-- FIX 1 — medical_documents.document_type (category, not file extension)
-- Normalize unknown values to 'other' before CHECK (safe for empty/MVP DBs).
-- ---------------------------------------------------------------------------

UPDATE public.medical_documents
SET document_type = 'other'
WHERE document_type IS NOT NULL
  AND document_type NOT IN (
    'prescription',
    'lab_result',
    'medical_letter',
    'other'
  );

DO $$
BEGIN
  ALTER TABLE public.medical_documents
    ADD CONSTRAINT medical_documents_document_type_check
    CHECK (
      document_type IN (
        'prescription',
        'lab_result',
        'medical_letter',
        'other'
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- FIX 2 — upload metadata (nullable for rows created under migration 001)
-- Backend MUST set these for every new upload and verify case access.
-- Role of uploader = profiles.role (do not duplicate role here).
-- ---------------------------------------------------------------------------

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS uploaded_by UUID
    REFERENCES public.profiles (id) ON DELETE SET NULL;

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS mime_type TEXT;

ALTER TABLE public.medical_documents
  ADD COLUMN IF NOT EXISTS size_bytes BIGINT;

-- Allow NULL mime_type for legacy rows; when set, must be MVP MIME.
DO $$
BEGIN
  ALTER TABLE public.medical_documents
    ADD CONSTRAINT medical_documents_mime_type_check
    CHECK (
      mime_type IS NULL
      OR mime_type IN (
        'application/pdf',
        'image/png',
        'image/jpeg'
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.medical_documents
    ADD CONSTRAINT medical_documents_size_bytes_check
    CHECK (size_bytes IS NULL OR size_bytes >= 0);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_medical_documents_uploaded_by
  ON public.medical_documents (uploaded_by);

-- ---------------------------------------------------------------------------
-- FIX 4 — ai_analyses.status + urgency CHECKs
-- Urgency labels are organizational (not diagnoses). No shared AI contract found
-- in MedFlow-AI at review time → use routine / review_required / potential_emergency.
-- Escalation still requires explicit safety rules + clinician judgment.
-- ---------------------------------------------------------------------------

UPDATE public.ai_analyses
SET status = 'pending'
WHERE status IS NOT NULL
  AND status NOT IN ('pending', 'completed', 'failed');

DO $$
BEGIN
  ALTER TABLE public.ai_analyses
    ADD CONSTRAINT ai_analyses_status_check
    CHECK (status IN ('pending', 'completed', 'failed'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Invalid urgency values → NULL (column stays nullable)
UPDATE public.ai_analyses
SET urgency = NULL
WHERE urgency IS NOT NULL
  AND urgency NOT IN (
    'routine',
    'review_required',
    'potential_emergency'
  );

DO $$
BEGIN
  ALTER TABLE public.ai_analyses
    ADD CONSTRAINT ai_analyses_urgency_check
    CHECK (
      urgency IS NULL
      OR urgency IN (
        'routine',
        'review_required',
        'potential_emergency'
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- Post-consultation conversation fields (minimal additive columns)
-- proposed_options kept as legacy/optional — not required for MVP workflow.
-- ---------------------------------------------------------------------------

ALTER TABLE public.ai_analyses
  ADD COLUMN IF NOT EXISTS context_relevance JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.ai_analyses
  ADD COLUMN IF NOT EXISTS patient_guidance TEXT;

ALTER TABLE public.ai_analyses
  ADD COLUMN IF NOT EXISTS doctor_draft TEXT;

ALTER TABLE public.ai_analyses
  ADD COLUMN IF NOT EXISTS summarized_until_message_id UUID
    REFERENCES public.case_messages (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ai_analyses_summarized_until
  ON public.ai_analyses (summarized_until_message_id);

-- ---------------------------------------------------------------------------
-- FIX 5 — set_cases_updated_at() with fixed search_path
-- Addresses Supabase Security Advisor: Function Search Path Mutable
-- Trigger trg_cases_updated_at from 001 is left in place.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_cases_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

COMMIT;

-- ---------------------------------------------------------------------------
-- FIX 3 / FIX 6 — documentation only (see SCHEMA.md):
-- Role checks (doctor_id / patient_id) are Backend responsibilities for MVP.
-- DB FK ensures profile exists; DB does NOT enforce role match.
-- ---------------------------------------------------------------------------
