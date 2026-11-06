-- MedFlow migration 003 — doctor orchestration state on cases
-- Apply AFTER 002_post_consultation_fixes.sql (do not edit 001 / 002).
-- Non-destructive: ADD COLUMN / ADD CONSTRAINT only.
-- Synthetic / hackathon data only. Do not run against production without review.
--
-- Why: DoctorOrchestrator (MedFlow-AI/cloud/orchestration/doctor-orchestrator.ts)
-- runs up to 2 clarification rounds per case. Each round is a separate HTTP
-- request to MedFlow-Backend, so the round counter and the last AI analysis must
-- be saved between requests. They are stored here, one JSON object per case.
--
-- Shape written by MedFlow-Backend (src/orchestrationStateStore.ts):
--   { "sessionId": "<case id>", "roundCount": 0..2, "lastAnalysis": { ... } }
-- NULL = no AI analysis has been requested for this case yet.
--
-- Privacy: lastAnalysis is the AI output computed on SCRUBBED data. The column
-- inherits RLS + service_role-only access from public.cases (migration 001).
-- Backend must NOT return this column to patients (GET /cases/:id does not select it).

BEGIN;

ALTER TABLE public.cases
  ADD COLUMN IF NOT EXISTS doctor_orchestration_state JSONB;

-- When set, the value must be a JSON object (not an array, string or number).
DO $$
BEGIN
  ALTER TABLE public.cases
    ADD CONSTRAINT cases_doctor_orchestration_state_object_check
    CHECK (
      doctor_orchestration_state IS NULL
      OR jsonb_typeof(doctor_orchestration_state) = 'object'
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMIT;
