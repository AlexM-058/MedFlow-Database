-- Fix PostgreSQL regex repetition bounds (RE_DUP_MAX is 255).
-- Keep the contract accepting 16..256 URL-safe characters; do not edit applied 004.
-- CREATE OR REPLACE preserves the restricted function grants from 004.
BEGIN;

CREATE OR REPLACE FUNCTION public.medflow_accept_doctor_invitation(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_inv public.doctor_invitations; v_email text;
BEGIN
  IF p_token IS NULL OR length(p_token) NOT BETWEEN 16 AND 256 OR p_token !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  -- Lock caller first, consistently with other account operations.
  v_profile := public.medflow_ensure_profile();
  SELECT lower(btrim(email)) INTO v_email FROM auth.users WHERE id=v_profile.id;
  SELECT * INTO v_inv FROM public.doctor_invitations
    WHERE token_hash=encode(pg_catalog.sha256(convert_to(p_token,'UTF8')),'hex') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  IF v_inv.email<>v_email THEN RAISE EXCEPTION USING MESSAGE='INVITATION_EMAIL_MISMATCH', ERRCODE='P0001'; END IF;
  IF v_inv.revoked_at IS NOT NULL THEN RAISE EXCEPTION USING MESSAGE='INVITATION_REVOKED', ERRCODE='P0001'; END IF;
  IF v_inv.consumed_at IS NOT NULL THEN
    IF v_inv.consumed_by=v_profile.id AND v_profile.role='doctor' THEN RETURN public.medflow_get_me(); END IF;
    RAISE EXCEPTION USING MESSAGE='INVITATION_USED', ERRCODE='P0001';
  END IF;
  IF v_inv.expires_at<=clock_timestamp() THEN RAISE EXCEPTION USING MESSAGE='INVITATION_EXPIRED', ERRCODE='P0001'; END IF;
  UPDATE public.profiles SET role='doctor',full_name=v_inv.full_name WHERE id=v_profile.id;
  INSERT INTO public.doctor_details(doctor_id,specialty,clinic) VALUES(v_profile.id,v_inv.specialty,v_inv.clinic)
    ON CONFLICT(doctor_id) DO UPDATE SET specialty=excluded.specialty,clinic=excluded.clinic;
  UPDATE public.doctor_invitations SET consumed_at=clock_timestamp(),consumed_by=v_profile.id WHERE id=v_inv.id;
  RETURN public.medflow_get_me();
END $$;

CREATE OR REPLACE FUNCTION public.medflow_preview_doctor(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_doctor jsonb;
BEGIN
  IF p_code IS NULL OR length(p_code) NOT BETWEEN 16 AND 256 OR p_code !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  SELECT public.medflow_doctor_json(doctor_id) INTO v_doctor FROM public.doctor_connection_codes WHERE code=p_code;
  IF v_doctor IS NULL THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  RETURN jsonb_build_object('doctor',v_doctor);
END $$;

CREATE OR REPLACE FUNCTION public.medflow_request_connection(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_doctor uuid; v_request uuid; v_created boolean := false;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF v_profile.role<>'patient' THEN RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  IF p_code IS NULL OR length(p_code) NOT BETWEEN 16 AND 256 OR p_code !~ '^[A-Za-z0-9_-]+$' THEN RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  -- Rotation waits for a submitted request to finish; a replaced code cannot be reused.
  SELECT c.doctor_id INTO v_doctor FROM public.doctor_connection_codes c
    JOIN public.profiles p ON p.id=c.doctor_id AND p.role='doctor'
    JOIN public.doctor_details d ON d.doctor_id=c.doctor_id
    WHERE c.code=p_code FOR SHARE OF c;
  IF v_doctor IS NULL THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  IF v_doctor=v_profile.id THEN RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_profile.id::text||':'||v_doctor::text,0));
  IF EXISTS(SELECT 1 FROM public.doctor_patient_assignments WHERE doctor_id=v_doctor AND patient_id=v_profile.id AND is_active) THEN
    SELECT id INTO v_request FROM public.connection_requests WHERE doctor_id=v_doctor AND patient_id=v_profile.id AND status='accepted' ORDER BY created_at DESC,id LIMIT 1;
    IF v_request IS NULL THEN
      INSERT INTO public.connection_requests(patient_id,doctor_id,status) VALUES(v_profile.id,v_doctor,'accepted') RETURNING id INTO v_request;
      v_created := true;
    END IF;
  ELSE
    SELECT id INTO v_request FROM public.connection_requests WHERE doctor_id=v_doctor AND patient_id=v_profile.id AND status='pending';
    IF v_request IS NULL THEN
      INSERT INTO public.connection_requests(patient_id,doctor_id) VALUES(v_profile.id,v_doctor) RETURNING id INTO v_request;
      v_created := true;
    END IF;
  END IF;
  RETURN jsonb_build_object('request',public.medflow_request_json(v_request),'created',v_created);
END $$;

COMMIT;
