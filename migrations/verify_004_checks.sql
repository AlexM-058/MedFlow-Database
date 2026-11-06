-- Run after 004 as postgres in a disposable/local database or reviewed SQL session.
-- Only synthetic rows created below are accessed. Everything rolls back.
BEGIN;
CREATE FUNCTION pg_temp.expect_error(p_sql text,p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM=p_message THEN RETURN; END IF;
    RAISE EXCEPTION 'Expected %, received %',p_message,SQLERRM;
  END;
  RAISE EXCEPTION 'Expected error %',p_message;
END $$;

DO $$
DECLARE
  v_patient uuid := gen_random_uuid(); v_doctor uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid(); v_second uuid := gen_random_uuid();
  v_unverified uuid := gen_random_uuid(); v_non_google uuid := gen_random_uuid();
  v_id uuid; v_email text; v_inv uuid; v_request uuid; v_again uuid;
  v_result jsonb; v_code text; v_new_code text; v_second_code text;
  v_token text := repeat('a',43); v_second_token text := repeat('b',43);
  v_expired text := repeat('c',43); v_revoked text := repeat('d',43);
  v_role text; v_table text; v_function text;
BEGIN
  -- ACL and RLS assertions do not enumerate account or medical data.
  FOREACH v_table IN ARRAY ARRAY['doctor_details','doctor_invitations','doctor_connection_codes','connection_requests'] LOOP
    IF NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=v_table AND c.relrowsecurity AND c.relforcerowsecurity) THEN
      RAISE EXCEPTION 'Missing forced RLS on %',v_table; END IF;
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated'] LOOP
      IF has_table_privilege(v_role,'public.'||v_table,'SELECT,INSERT,UPDATE,DELETE') THEN
        RAISE EXCEPTION 'Unexpected table grant for % on %',v_role,v_table; END IF;
    END LOOP;
  END LOOP;
  IF NOT has_function_privilege('anon','public.medflow_preview_doctor(text)','EXECUTE') THEN RAISE EXCEPTION 'Preview grant missing'; END IF;
  IF has_function_privilege('anon','public.medflow_get_me()','EXECUTE') THEN RAISE EXCEPTION 'Anonymous private RPC'; END IF;
  FOREACH v_function IN ARRAY ARRAY['public.medflow_ensure_profile()','public.medflow_doctor_json(uuid)','public.medflow_request_json(uuid)',
    'public.medflow_create_doctor_invitation(text,text,text,text,text)','public.medflow_revoke_doctor_invitation(uuid)'] LOOP
    IF has_function_privilege('authenticated',v_function,'EXECUTE') THEN RAISE EXCEPTION 'Private helper/operator RPC exposed: %',v_function; END IF;
  END LOOP;
  IF NOT has_function_privilege('service_role','public.medflow_create_doctor_invitation(text,text,text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'Operator grant missing'; END IF;

  FOREACH v_id IN ARRAY ARRAY[v_patient,v_doctor,v_other,v_second,v_unverified,v_non_google] LOOP
    v_email := v_id::text||'@example.invalid';
    INSERT INTO auth.users(id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
      VALUES(v_id,'authenticated','authenticated',v_email,
        CASE WHEN v_id=v_unverified THEN NULL ELSE now() END,
        '{"provider":"google","providers":["google"]}',
        '{"full_name":"Synthetic account","role":"doctor"}');
    IF v_id<>v_non_google THEN
      INSERT INTO auth.identities(id,user_id,provider_id,provider,identity_data)
        VALUES(gen_random_uuid(),v_id,v_id::text,'google',jsonb_build_object('sub',v_id,'email',v_email,'email_verified',true));
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub','',true);
  PERFORM set_config('request.jwt.claims','{}',true);
  PERFORM pg_temp.expect_error('SELECT public.medflow_get_me()','AUTH_REQUIRED');
  PERFORM set_config('request.jwt.claim.sub',v_unverified::text,true);
  PERFORM pg_temp.expect_error('SELECT public.medflow_get_me()','GOOGLE_REQUIRED');
  PERFORM set_config('request.jwt.claim.sub',v_non_google::text,true);
  PERFORM pg_temp.expect_error('SELECT public.medflow_get_me()','GOOGLE_REQUIRED');
  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  v_result := public.medflow_get_me();
  IF v_result#>>'{profile,role}'<>'patient' OR v_result#>'{profile,activeDoctors}'<>'[]'::jsonb THEN RAISE EXCEPTION 'Patient bootstrap trusts metadata'; END IF;
  PERFORM public.medflow_get_me();
  IF (SELECT count(*) FROM public.profiles WHERE id=v_patient)<>1 THEN RAISE EXCEPTION 'Duplicate bootstrap'; END IF;
  PERFORM pg_temp.expect_error('SELECT public.medflow_get_connection_code()','FORBIDDEN');
  -- Regression for 005: PostgreSQL regex repetition bounds stop at 255;
  -- the API permits 256 characters and must reject 257 through length checks.
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',repeat('x',256)),'NOT_FOUND');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',repeat('x',257)),'INVALID_INPUT');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_preview_doctor(%L)',repeat('x',256)),'NOT_FOUND');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_preview_doctor(%L)',repeat('x',257)),'INVALID_INPUT');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_request_connection(%L)',repeat('x',256)),'NOT_FOUND');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_request_connection(%L)',repeat('x',257)),'INVALID_INPUT');

  v_result := public.medflow_create_doctor_invitation(v_doctor::text||'@example.invalid','Synthetic Doctor','General medicine','Synthetic clinic',encode(sha256(convert_to(v_token,'UTF8')),'hex'));
  v_inv := (v_result->>'id')::uuid;
  IF (v_result->>'expiresAt')::timestamptz NOT BETWEEN now()+interval '6 days 23 hours' AND now()+interval '7 days 1 hour' THEN RAISE EXCEPTION 'Invitation expiry'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',v_token),'INVITATION_EMAIL_MISMATCH');
  PERFORM set_config('request.jwt.claim.sub',v_doctor::text,true);
  v_result := public.medflow_accept_doctor_invitation(v_token);
  IF v_result#>>'{profile,role}'<>'doctor' THEN RAISE EXCEPTION 'Promotion failed'; END IF;
  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',v_token),'INVITATION_EMAIL_MISMATCH');
  PERFORM set_config('request.jwt.claim.sub',v_doctor::text,true);
  UPDATE public.doctor_invitations SET expires_at=now()-interval '1 day' WHERE id=v_inv;
  PERFORM public.medflow_accept_doctor_invitation(v_token); -- same identity retry remains valid after expiry
  v_code := public.medflow_get_connection_code()#>>'{connectionCode,code}';
  IF length(v_code)<>64 OR public.medflow_preview_doctor(v_code)#>>'{doctor,specialty}'<>'General medicine' THEN RAISE EXCEPTION 'Code/preview'; END IF;
  IF (public.medflow_preview_doctor(v_code)->'doctor') ? 'email' THEN RAISE EXCEPTION 'Public email leak'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_request_connection(%L)',v_code),'FORBIDDEN');
  PERFORM public.medflow_revoke_doctor_invitation(v_inv);
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',v_token),'INVITATION_REVOKED');

  -- Expired and revoked unused invitations never promote the account.
  v_result := public.medflow_create_doctor_invitation(v_other::text||'@example.invalid','Synthetic Other','General','Clinic',encode(sha256(convert_to(v_expired,'UTF8')),'hex'));
  UPDATE public.doctor_invitations SET expires_at=now()-interval '1 second' WHERE id=(v_result->>'id')::uuid;
  v_result := public.medflow_create_doctor_invitation(v_other::text||'@example.invalid','Synthetic Other','General','Clinic',encode(sha256(convert_to(v_revoked,'UTF8')),'hex'));
  PERFORM public.medflow_revoke_doctor_invitation((v_result->>'id')::uuid);
  PERFORM set_config('request.jwt.claim.sub',v_other::text,true);
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',v_expired),'INVITATION_EXPIRED');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_accept_doctor_invitation(%L)',v_revoked),'INVITATION_REVOKED');

  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  v_result := public.medflow_request_connection(v_code); v_request := (v_result#>>'{request,id}')::uuid;
  v_again := (public.medflow_request_connection(v_code)#>>'{request,id}')::uuid;
  IF v_request<>v_again OR v_result#>>'{request,status}'<>'pending' THEN RAISE EXCEPTION 'Pending idempotency'; END IF;
  IF EXISTS(SELECT 1 FROM public.doctor_patient_assignments WHERE patient_id=v_patient) THEN RAISE EXCEPTION 'Request granted active access'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_update_connection(%L,''accept'')',v_request),'FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',v_other::text,true);
  IF public.medflow_list_connection_requests()->'requests'<>'[]'::jsonb THEN RAISE EXCEPTION 'Request list leakage'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_update_connection(%L,''cancel'')',v_request),'FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',v_doctor::text,true);
  PERFORM public.medflow_update_connection(v_request,'reject');
  PERFORM public.medflow_update_connection(v_request,'reject');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_update_connection(%L,''accept'')',v_request),'CONNECTION_NOT_PENDING');
  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  v_again := (public.medflow_request_connection(v_code)#>>'{request,id}')::uuid;
  IF v_again=v_request THEN RAISE EXCEPTION 'Terminal request reused'; END IF;
  PERFORM public.medflow_update_connection(v_again,'cancel');
  PERFORM public.medflow_update_connection(v_again,'cancel');
  v_request := (public.medflow_request_connection(v_code)#>>'{request,id}')::uuid;
  PERFORM set_config('request.jwt.claim.sub',v_doctor::text,true);
  v_new_code := public.medflow_rotate_connection_code()#>>'{connectionCode,code}';
  IF v_new_code=v_code THEN RAISE EXCEPTION 'Code not rotated'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_preview_doctor(%L)',v_code),'NOT_FOUND');
  -- An invitation may promote a patient while an older request is pending;
  -- accepting that request must recheck the persisted target role.
  UPDATE public.profiles SET role='doctor' WHERE id=v_patient;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_update_connection(%L,''accept'')',v_request),'FORBIDDEN');
  IF (SELECT status FROM public.connection_requests WHERE id=v_request)<>'pending'
    OR EXISTS(SELECT 1 FROM public.doctor_patient_assignments WHERE patient_id=v_patient AND doctor_id=v_doctor AND is_active) THEN
    RAISE EXCEPTION 'Role failure mutated connection state'; END IF;
  UPDATE public.profiles SET role='patient' WHERE id=v_patient;
  -- A later failure rolls back both the assignment and the status transition.
  BEGIN
    PERFORM public.medflow_update_connection(v_request,'accept');
    RAISE EXCEPTION USING MESSAGE='SYNTHETIC_ROLLBACK', ERRCODE='P0001';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM<>'SYNTHETIC_ROLLBACK' THEN RAISE; END IF;
  END;
  IF (SELECT status FROM public.connection_requests WHERE id=v_request)<>'pending'
    OR EXISTS(SELECT 1 FROM public.doctor_patient_assignments WHERE patient_id=v_patient AND doctor_id=v_doctor AND is_active) THEN
    RAISE EXCEPTION 'Acceptance did not roll back atomically'; END IF;
  PERFORM public.medflow_update_connection(v_request,'accept'); -- rotation preserves existing pending
  PERFORM public.medflow_update_connection(v_request,'accept');
  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  IF (public.medflow_request_connection(v_new_code)#>>'{request,id}')::uuid<>v_request THEN RAISE EXCEPTION 'Accepted idempotency'; END IF;
  IF (SELECT count(*) FROM public.doctor_patient_assignments WHERE patient_id=v_patient AND doctor_id=v_doctor AND is_active)<>1 THEN RAISE EXCEPTION 'Assignment atomicity'; END IF;

  -- Legacy active association gains a request record, without another assignment.
  PERFORM public.medflow_create_doctor_invitation(v_second::text||'@example.invalid','Synthetic Second','General','Clinic',encode(sha256(convert_to(v_second_token,'UTF8')),'hex'));
  PERFORM set_config('request.jwt.claim.sub',v_second::text,true);
  PERFORM public.medflow_accept_doctor_invitation(v_second_token);
  v_second_code := public.medflow_get_connection_code()#>>'{connectionCode,code}';
  INSERT INTO public.doctor_patient_assignments(patient_id,doctor_id) VALUES(v_patient,v_second);
  PERFORM set_config('request.jwt.claim.sub',v_patient::text,true);
  v_result := public.medflow_request_connection(v_second_code);
  IF v_result#>>'{request,status}'<>'accepted' THEN RAISE EXCEPTION 'Legacy active pair'; END IF;
  IF jsonb_array_length(public.medflow_get_me()#>'{profile,activeDoctors}')<>2 THEN RAISE EXCEPTION 'Multiple doctors not preserved'; END IF;
  IF (SELECT count(*) FROM public.doctor_patient_assignments WHERE patient_id=v_patient AND is_active)<>2 THEN RAISE EXCEPTION 'Duplicate legacy assignment'; END IF;
  RAISE NOTICE '004 synthetic auth/connection checks passed; rolling back fixtures';
END $$;
ROLLBACK;

-- Concurrency: production functions take a caller profile row lock; request POST
-- also takes a pair advisory xact lock and has a partial unique pending index.
-- Two concurrent POSTs for one patient must return the same pending id. Doctor
-- transitions use FOR UPDATE on the request, so competing accept/reject yields
-- one winner and CONNECTION_NOT_PENDING for the loser. Code SELECT FOR SHARE
-- serializes request creation against rotation. Run two separate transactions
-- in a local integration harness to exercise actual waiting (not simulated here).
