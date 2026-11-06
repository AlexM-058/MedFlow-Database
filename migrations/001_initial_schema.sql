-- MedFlow initial schema (Supabase PostgreSQL)
-- Apply manually via Supabase SQL Editor or CLI.
-- Synthetic / hackathon data only. Do not store real patient data.
-- Uses built-in gen_random_uuid() (PostgreSQL 13+ / Supabase default).

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('patient', 'doctor')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.doctor_patient_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  patient_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT doctor_patient_assignments_distinct_users
    CHECK (doctor_id <> patient_id)
);

-- One active assignment per doctor–patient pair
CREATE UNIQUE INDEX IF NOT EXISTS doctor_patient_assignments_active_unique
  ON public.doctor_patient_assignments (doctor_id, patient_id)
  WHERE is_active = true;

CREATE TABLE IF NOT EXISTS public.medical_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  record_type TEXT NOT NULL,
  clinical_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  doctor_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN (
      'draft',
      'awaiting_patient',
      'pending_doctor',
      'approved',
      'closed'
    )
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.case_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES public.cases (id) ON DELETE CASCADE,
  sender_role TEXT NOT NULL CHECK (
    sender_role IN ('patient', 'doctor', 'ai', 'system')
  ),
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.medical_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES public.cases (id) ON DELETE CASCADE,
  document_type TEXT NOT NULL,
  extracted_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_analyses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES public.cases (id) ON DELETE CASCADE,
  model_name TEXT NOT NULL,
  case_summary TEXT,
  symptoms JSONB NOT NULL DEFAULT '[]'::jsonb,
  urgency TEXT,
  follow_up_questions JSONB NOT NULL DEFAULT '[]'::jsonb,
  proposed_options JSONB NOT NULL DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.doctor_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES public.cases (id) ON DELETE CASCADE,
  doctor_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  ai_analysis_id UUID REFERENCES public.ai_analyses (id) ON DELETE SET NULL,
  decision_type TEXT NOT NULL CHECK (
    decision_type IN ('approved', 'modified', 'custom', 'rejected')
  ),
  final_response TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.cloud_disclosures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id UUID NOT NULL REFERENCES public.cases (id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  model_name TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- updated_at helper for cases
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_cases_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cases_updated_at ON public.cases;
CREATE TRIGGER trg_cases_updated_at
  BEFORE UPDATE ON public.cases
  FOR EACH ROW
  EXECUTE FUNCTION public.set_cases_updated_at();

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_profiles_role
  ON public.profiles (role);

CREATE INDEX IF NOT EXISTS idx_assignments_doctor
  ON public.doctor_patient_assignments (doctor_id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_assignments_patient
  ON public.doctor_patient_assignments (patient_id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_medical_records_patient
  ON public.medical_records (patient_id);

CREATE INDEX IF NOT EXISTS idx_cases_patient
  ON public.cases (patient_id);

CREATE INDEX IF NOT EXISTS idx_cases_doctor
  ON public.cases (doctor_id);

CREATE INDEX IF NOT EXISTS idx_cases_status
  ON public.cases (status);

CREATE INDEX IF NOT EXISTS idx_case_messages_case
  ON public.case_messages (case_id, created_at);

CREATE INDEX IF NOT EXISTS idx_medical_documents_case
  ON public.medical_documents (case_id);

CREATE INDEX IF NOT EXISTS idx_ai_analyses_case
  ON public.ai_analyses (case_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_doctor_decisions_case
  ON public.doctor_decisions (case_id);

CREATE INDEX IF NOT EXISTS idx_cloud_disclosures_case
  ON public.cloud_disclosures (case_id);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- Medical tables: RLS ON, no public/anon/authenticated policies.
-- FastAPI uses the service_role key and MUST enforce authorization in code.
-- ---------------------------------------------------------------------------

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_patient_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medical_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.case_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medical_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_analyses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cloud_disclosures ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_patient_assignments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.medical_records FORCE ROW LEVEL SECURITY;
ALTER TABLE public.cases FORCE ROW LEVEL SECURITY;
ALTER TABLE public.case_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE public.medical_documents FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_analyses FORCE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_decisions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.cloud_disclosures FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Privileges: revoke from anon/authenticated; grant to service_role
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.profiles FROM anon, authenticated;
REVOKE ALL ON TABLE public.doctor_patient_assignments FROM anon, authenticated;
REVOKE ALL ON TABLE public.medical_records FROM anon, authenticated;
REVOKE ALL ON TABLE public.cases FROM anon, authenticated;
REVOKE ALL ON TABLE public.case_messages FROM anon, authenticated;
REVOKE ALL ON TABLE public.medical_documents FROM anon, authenticated;
REVOKE ALL ON TABLE public.ai_analyses FROM anon, authenticated;
REVOKE ALL ON TABLE public.doctor_decisions FROM anon, authenticated;
REVOKE ALL ON TABLE public.cloud_disclosures FROM anon, authenticated;

GRANT ALL ON TABLE public.profiles TO service_role;
GRANT ALL ON TABLE public.doctor_patient_assignments TO service_role;
GRANT ALL ON TABLE public.medical_records TO service_role;
GRANT ALL ON TABLE public.cases TO service_role;
GRANT ALL ON TABLE public.case_messages TO service_role;
GRANT ALL ON TABLE public.medical_documents TO service_role;
GRANT ALL ON TABLE public.ai_analyses TO service_role;
GRANT ALL ON TABLE public.doctor_decisions TO service_role;
GRANT ALL ON TABLE public.cloud_disclosures TO service_role;

GRANT USAGE ON SCHEMA public TO service_role;
