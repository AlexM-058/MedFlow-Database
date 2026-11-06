-- Google identity, invitation-only doctors, explicit patient connection requests.
-- Apply as the Supabase migration owner (postgres); no existing medical rows change.
BEGIN;

CREATE TABLE public.doctor_details (
  doctor_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  specialty text NOT NULL CHECK (length(btrim(specialty)) BETWEEN 1 AND 200),
  clinic text NOT NULL CHECK (length(btrim(clinic)) BETWEEN 1 AND 300)
);
CREATE TABLE public.doctor_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL CHECK (email = lower(btrim(email)) AND length(email) BETWEEN 3 AND 320),
  full_name text NOT NULL CHECK (length(btrim(full_name)) BETWEEN 1 AND 200),
  specialty text NOT NULL CHECK (length(btrim(specialty)) BETWEEN 1 AND 200),
  clinic text NOT NULL CHECK (length(btrim(clinic)) BETWEEN 1 AND 300),
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
  revoked_at timestamptz,
  consumed_at timestamptz,
  consumed_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CHECK ((consumed_at IS NULL) = (consumed_by IS NULL))
);
CREATE INDEX doctor_invitations_consumed_by_idx ON public.doctor_invitations(consumed_by);
CREATE TABLE public.doctor_connection_codes (
  doctor_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  code text NOT NULL UNIQUE CHECK (code ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.connection_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  doctor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (patient_id <> doctor_id)
);
CREATE UNIQUE INDEX connection_requests_pending_pair_idx ON public.connection_requests(patient_id,doctor_id) WHERE status = 'pending';
CREATE INDEX connection_requests_patient_status_idx ON public.connection_requests(patient_id,status,created_at DESC);
CREATE INDEX connection_requests_doctor_status_idx ON public.connection_requests(doctor_id,status,created_at DESC);
CREATE INDEX connection_requests_pair_idx ON public.connection_requests(patient_id,doctor_id,created_at DESC);

ALTER TABLE public.doctor_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_details FORCE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_invitations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_connection_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_connection_codes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.connection_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connection_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.doctor_details,public.doctor_invitations,public.doctor_connection_codes,public.connection_requests FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.doctor_details,public.doctor_invitations,public.doctor_connection_codes,public.connection_requests TO service_role;

-- Helpers are deliberately not executable by browser/service roles. Public RPCs
-- run as the migration owner and always derive the caller from the verified JWT.
CREATE FUNCTION public.medflow_ensure_profile() RETURNS public.profiles
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
  SELECT * INTO STRICT v_profile FROM public.profiles WHERE id=v_id FOR UPDATE;
  RETURN v_profile;
END $$;

CREATE FUNCTION public.medflow_doctor_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id',p.id,'fullName',p.full_name,'specialty',d.specialty,'clinic',d.clinic)
  FROM public.profiles p JOIN public.doctor_details d ON d.doctor_id=p.id
  WHERE p.id=p_id AND p.role='doctor'
$$;
CREATE FUNCTION public.medflow_request_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('id',r.id,'status',r.status,'createdAt',r.created_at,
    'doctor',public.medflow_doctor_json(r.doctor_id),
    'patient',jsonb_build_object('id',p.id,'fullName',p.full_name))
  FROM public.connection_requests r JOIN public.profiles p ON p.id=r.patient_id WHERE r.id=p_id
$$;

CREATE FUNCTION public.medflow_get_me() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_email text; v_doctors jsonb;
BEGIN
  v_profile := public.medflow_ensure_profile();
  SELECT email INTO v_email FROM auth.users WHERE id=v_profile.id;
  SELECT coalesce(jsonb_agg(public.medflow_doctor_json(a.doctor_id) ORDER BY a.doctor_id)
    FILTER (WHERE d.doctor_id IS NOT NULL AND p.role='doctor'),'[]'::jsonb) INTO v_doctors
  FROM public.doctor_patient_assignments a
    JOIN public.profiles p ON p.id=a.doctor_id
    LEFT JOIN public.doctor_details d ON d.doctor_id=a.doctor_id
  WHERE a.patient_id=v_profile.id AND a.is_active;
  RETURN jsonb_build_object('profile',jsonb_build_object('id',v_profile.id,'email',v_email,
    'fullName',v_profile.full_name,'role',v_profile.role,'activeDoctors',v_doctors));
END $$;

CREATE FUNCTION public.medflow_accept_doctor_invitation(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_inv public.doctor_invitations; v_email text;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{16,256}$' THEN
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

CREATE FUNCTION public.medflow_preview_doctor(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_doctor jsonb;
BEGIN
  IF p_code IS NULL OR p_code !~ '^[A-Za-z0-9_-]{16,256}$' THEN
    RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  SELECT public.medflow_doctor_json(doctor_id) INTO v_doctor FROM public.doctor_connection_codes WHERE code=p_code;
  IF v_doctor IS NULL THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  RETURN jsonb_build_object('doctor',v_doctor);
END $$;

CREATE FUNCTION public.medflow_list_connection_requests() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_requests jsonb;
BEGIN
  v_profile := public.medflow_ensure_profile();
  SELECT coalesce(jsonb_agg(public.medflow_request_json(id) ORDER BY created_at DESC,id),'[]'::jsonb)
    INTO v_requests FROM public.connection_requests
    WHERE (v_profile.role='patient' AND patient_id=v_profile.id) OR (v_profile.role='doctor' AND doctor_id=v_profile.id);
  RETURN jsonb_build_object('requests',v_requests);
END $$;

CREATE FUNCTION public.medflow_request_connection(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_doctor uuid; v_request uuid; v_created boolean := false;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF v_profile.role<>'patient' THEN RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  IF p_code IS NULL OR p_code !~ '^[A-Za-z0-9_-]{16,256}$' THEN RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
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

CREATE FUNCTION public.medflow_update_connection(p_id uuid,p_action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_request public.connection_requests; v_status text;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF p_id IS NULL OR p_action IS NULL OR p_action NOT IN ('accept','reject','cancel') THEN RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  SELECT * INTO v_request FROM public.connection_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  IF (p_action='cancel' AND (v_profile.role<>'patient' OR v_profile.id<>v_request.patient_id))
    OR (p_action IN ('accept','reject') AND (v_profile.role<>'doctor' OR v_profile.id<>v_request.doctor_id)) THEN
    RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  v_status := CASE p_action WHEN 'accept' THEN 'accepted' WHEN 'reject' THEN 'rejected' ELSE 'cancelled' END;
  IF v_request.status=v_status THEN RETURN jsonb_build_object('request',public.medflow_request_json(p_id)); END IF;
  IF v_request.status<>'pending' THEN RAISE EXCEPTION USING MESSAGE='CONNECTION_NOT_PENDING', ERRCODE='P0001'; END IF;
  IF p_action='accept' THEN
    IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_request.patient_id AND role='patient') THEN
      RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
    INSERT INTO public.doctor_patient_assignments(doctor_id,patient_id,is_active) VALUES(v_request.doctor_id,v_request.patient_id,true)
      ON CONFLICT(doctor_id,patient_id) WHERE is_active=true DO NOTHING;
  END IF;
  UPDATE public.connection_requests SET status=v_status,updated_at=clock_timestamp() WHERE id=p_id;
  RETURN jsonb_build_object('request',public.medflow_request_json(p_id));
END $$;

CREATE FUNCTION public.medflow_get_connection_code() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_code text;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF v_profile.role<>'doctor' OR NOT EXISTS(SELECT 1 FROM public.doctor_details WHERE doctor_id=v_profile.id) THEN
    RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  INSERT INTO public.doctor_connection_codes(doctor_id,code) VALUES(v_profile.id,encode(extensions.gen_random_bytes(32),'hex')) ON CONFLICT(doctor_id) DO NOTHING;
  SELECT code INTO v_code FROM public.doctor_connection_codes WHERE doctor_id=v_profile.id;
  RETURN jsonb_build_object('connectionCode',jsonb_build_object('code',v_code));
END $$;
CREATE FUNCTION public.medflow_rotate_connection_code() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_profile public.profiles; v_code text;
BEGIN
  v_profile := public.medflow_ensure_profile();
  IF v_profile.role<>'doctor' OR NOT EXISTS(SELECT 1 FROM public.doctor_details WHERE doctor_id=v_profile.id) THEN
    RAISE EXCEPTION USING MESSAGE='FORBIDDEN', ERRCODE='P0001'; END IF;
  INSERT INTO public.doctor_connection_codes(doctor_id,code) VALUES(v_profile.id,encode(extensions.gen_random_bytes(32),'hex'))
    ON CONFLICT(doctor_id) DO UPDATE SET code=excluded.code,created_at=clock_timestamp() RETURNING code INTO v_code;
  RETURN jsonb_build_object('connectionCode',jsonb_build_object('code',v_code));
END $$;

CREATE FUNCTION public.medflow_create_doctor_invitation(p_email text,p_full_name text,p_specialty text,p_clinic text,p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_expires timestamptz;
BEGIN
  IF p_email IS NULL OR length(btrim(p_email)) NOT BETWEEN 3 AND 320 OR btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    OR p_full_name IS NULL OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 200
    OR p_specialty IS NULL OR length(btrim(p_specialty)) NOT BETWEEN 1 AND 200
    OR p_clinic IS NULL OR length(btrim(p_clinic)) NOT BETWEEN 1 AND 300
    OR p_token_hash IS NULL OR p_token_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  INSERT INTO public.doctor_invitations(email,full_name,specialty,clinic,token_hash)
    VALUES(lower(btrim(p_email)),btrim(p_full_name),btrim(p_specialty),btrim(p_clinic),p_token_hash)
    RETURNING id,expires_at INTO v_id,v_expires;
  RETURN jsonb_build_object('id',v_id,'expiresAt',v_expires);
END $$;
CREATE FUNCTION public.medflow_revoke_doctor_invitation(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.doctor_invitations SET revoked_at=coalesce(revoked_at,clock_timestamp()) WHERE id=p_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='NOT_FOUND', ERRCODE='P0001'; END IF;
  -- Revocation blocks invitation reuse; it does not revoke an existing doctor's role.
  RETURN jsonb_build_object('id',p_id,'revoked',true);
END $$;

-- Remove PostgreSQL's default PUBLIC execute, including internal helpers.
REVOKE ALL ON FUNCTION public.medflow_ensure_profile(),public.medflow_doctor_json(uuid),public.medflow_request_json(uuid),
  public.medflow_get_me(),public.medflow_accept_doctor_invitation(text),public.medflow_preview_doctor(text),
  public.medflow_list_connection_requests(),public.medflow_request_connection(text),public.medflow_update_connection(uuid,text),
  public.medflow_get_connection_code(),public.medflow_rotate_connection_code(),
  public.medflow_create_doctor_invitation(text,text,text,text,text),public.medflow_revoke_doctor_invitation(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.medflow_preview_doctor(text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.medflow_get_me(),public.medflow_accept_doctor_invitation(text),
  public.medflow_list_connection_requests(),public.medflow_request_connection(text),public.medflow_update_connection(uuid,text),
  public.medflow_get_connection_code(),public.medflow_rotate_connection_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.medflow_create_doctor_invitation(text,text,text,text,text),public.medflow_revoke_doctor_invitation(uuid) TO service_role;

COMMIT;
