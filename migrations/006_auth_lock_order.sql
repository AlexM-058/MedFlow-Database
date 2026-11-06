-- Preserve FK lock compatibility and serialize patient role checks.
-- CREATE OR REPLACE retains restricted RPC/helper execute grants.
BEGIN;

CREATE OR REPLACE FUNCTION public.medflow_ensure_profile() RETURNS public.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user auth.users; v_profile public.profiles; v_id uuid := auth.uid();
BEGIN
  IF v_id IS NULL THEN RAISE EXCEPTION USING MESSAGE='AUTH_REQUIRED', ERRCODE='P0001'; END IF;
  SELECT * INTO v_user FROM auth.users WHERE id=v_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='AUTH_REQUIRED', ERRCODE='P0001'; END IF;
  IF v_user.email IS NULL OR v_user.email_confirmed_at IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.identities WHERE user_id=v_id AND provider='google'
  ) THEN RAISE EXCEPTION USING MESSAGE='GOOGLE_REQUIRED', ERRCODE='P0001'; END IF;
  -- Name is display-only; email is trusted auth state. Metadata never sets role.
  INSERT INTO public.profiles(id,full_name,role)
    VALUES (v_id,coalesce(nullif(btrim(v_user.raw_user_meta_data->>'full_name'),''),v_user.email),'patient')
    ON CONFLICT(id) DO NOTHING;
  -- Non-key updates serialize account changes while remaining compatible with
  -- FK FOR KEY SHARE checks. FOR UPDATE here can deadlock QR rotation against
  -- patient request insertion (which holds the code row FOR SHARE).
  SELECT * INTO STRICT v_profile FROM public.profiles WHERE id=v_id FOR NO KEY UPDATE;
  RETURN v_profile;
END $$;

CREATE OR REPLACE FUNCTION public.medflow_update_connection(p_id uuid,p_action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_profile public.profiles;
  v_request public.connection_requests;
  v_initial public.connection_requests;
  v_patient_role text;
  v_status text;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF p_id IS NULL OR p_action IS NULL OR p_action NOT IN ('accept','reject','cancel') THEN
    RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  -- Read only to authorize before locking another account. Participants cannot
  -- be edited through this API. Recheck them after taking the request lock.
  SELECT * INTO v_initial FROM public.connection_requests WHERE id=p_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  IF (p_action='cancel' AND (v_profile.role<>'patient' OR v_profile.id<>v_initial.patient_id))
    OR (p_action IN ('accept','reject') AND (v_profile.role<>'doctor' OR v_profile.id<>v_initial.doctor_id)) THEN
    RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  IF p_action='accept' THEN
    -- Lock the target patient BEFORE the request. Role promotion takes NO KEY
    -- UPDATE, so SHARE serializes role validation against invitation promotion.
    -- Locking the request first could cycle with patient cancellation, which
    -- already holds its own profile lock before attempting the request lock.
    -- Filter before locking: stale requests whose patient already became a
    -- doctor must not acquire a second doctor's profile lock in reverse order.
    SELECT role INTO v_patient_role FROM public.profiles
      WHERE id=v_initial.patient_id AND role='patient' FOR SHARE;
  END IF;
  SELECT * INTO v_request FROM public.connection_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  IF v_request.patient_id<>v_initial.patient_id OR v_request.doctor_id<>v_initial.doctor_id THEN
    RAISE EXCEPTION USING MESSAGE='CONNECTION_NOT_PENDING', ERRCODE='P0001'; END IF;
  v_status := CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'reject' THEN 'rejected' ELSE 'cancelled' END;
  IF v_request.status=v_status THEN RETURN jsonb_build_object('request',public.medflow_request_json(p_id)); END IF;
  IF v_request.status<>'pending' THEN RAISE EXCEPTION USING MESSAGE='CONNECTION_NOT_PENDING', ERRCODE='P0001'; END IF;
  IF p_action='accept' THEN
    IF v_patient_role IS DISTINCT FROM 'patient' THEN
      RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
    INSERT INTO public.doctor_patient_assignments(doctor_id,patient_id,is_active)
      VALUES(v_request.doctor_id,v_request.patient_id,true)
      ON CONFLICT(doctor_id,patient_id) WHERE is_active=true DO NOTHING;
  END IF;
  UPDATE public.connection_requests SET status=v_status,updated_at=clock_timestamp() WHERE id=p_id;
  RETURN jsonb_build_object('request',public.medflow_request_json(p_id));
END $$;

COMMIT;
