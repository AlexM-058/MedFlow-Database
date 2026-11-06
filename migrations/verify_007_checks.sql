-- Run after 007 as postgres in a disposable/local database or a reviewed SQL session.
-- Only synthetic rows created below are touched. Everything rolls back.
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
-- Runs p_sql as a real database role; succeeds only if PostgreSQL denies it (42501).
CREATE FUNCTION pg_temp.expect_denied(p_role text,p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I',p_role);
    EXECUTE p_sql;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE; RETURN;
  END;
  RESET ROLE;
  RAISE EXCEPTION 'Expected permission denied for % on: %',p_role,p_sql;
END $$;

DO $$
DECLARE
  v_admin uuid := gen_random_uuid(); v_user uuid := gen_random_uuid();
  v_id uuid; v_result jsonb; v_invitation uuid; v_role text; v_function text;
  v_hash text := encode(sha256(convert_to('synthetic-admin-check-token','UTF8')),'hex');
  v_public text[] := ARRAY['public.medflow_admin_status()',
    'public.medflow_admin_create_doctor_invitation(text,text,text,text,text)',
    'public.medflow_admin_list_doctor_invitations()','public.medflow_admin_revoke_doctor_invitation(uuid)'];
BEGIN
  -- 1. Table: forced RLS and no browser-role privileges.
  IF NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='platform_admins' AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'Missing forced RLS on platform_admins'; END IF;
  FOREACH v_role IN ARRAY ARRAY['anon','authenticated'] LOOP
    IF has_table_privilege(v_role,'public.platform_admins','SELECT,INSERT,UPDATE,DELETE') THEN
      RAISE EXCEPTION 'Unexpected platform_admins grant for %',v_role; END IF;
  END LOOP;

  -- 2. Function grants: anon gets nothing; authenticated only the four checked RPCs.
  FOREACH v_function IN ARRAY v_public LOOP
    IF has_function_privilege('anon',v_function,'EXECUTE') THEN RAISE EXCEPTION 'Anonymous admin RPC: %',v_function; END IF;
    IF NOT has_function_privilege('authenticated',v_function,'EXECUTE') THEN RAISE EXCEPTION 'Missing grant: %',v_function; END IF;
  END LOOP;
  FOREACH v_function IN ARRAY ARRAY['public.medflow_require_admin()','public.medflow_admin_invitation_json(uuid)',
    'public.medflow_create_doctor_invitation(text,text,text,text,text)','public.medflow_revoke_doctor_invitation(uuid)'] LOOP
    IF has_function_privilege('anon',v_function,'EXECUTE') OR has_function_privilege('authenticated',v_function,'EXECUTE') THEN
      RAISE EXCEPTION 'Private helper exposed: %',v_function; END IF;
  END LOOP;

  -- 3. No self-promotion path: no function writes platform_admins.
  IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+public\.platform_admins') THEN
    RAISE EXCEPTION 'A function writes platform_admins'; END IF;

  -- Synthetic accounts (profiles are created directly; no Google identity needed here).
  FOREACH v_id IN ARRAY ARRAY[v_admin,v_user] LOOP
    INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
      VALUES(v_id,'authenticated','authenticated',v_id::text||'@example.invalid',now());
    INSERT INTO public.profiles(id,full_name,role) VALUES(v_id,'Synthetic account','patient');
  END LOOP;
  -- Onboarding step performed by the operator (postgres/service_role only).
  INSERT INTO public.platform_admins(user_id) VALUES(v_admin);

  -- 4. Real role checks: anon cannot execute; authenticated cannot write the table.
  PERFORM pg_temp.expect_denied('anon','SELECT public.medflow_admin_status()');
  PERFORM pg_temp.expect_denied('anon','SELECT public.medflow_admin_list_doctor_invitations()');
  PERFORM pg_temp.expect_denied('anon',format('SELECT public.medflow_admin_create_doctor_invitation(%L,%L,%L,%L,%L)',
    'x@example.invalid','Synthetic Doctor','Family medicine','Synthetic Clinic',v_hash));
  PERFORM pg_temp.expect_denied('authenticated',format('INSERT INTO public.platform_admins(user_id) VALUES(%L)',v_user));
  PERFORM pg_temp.expect_denied('authenticated','SELECT 1 FROM public.platform_admins');
  PERFORM pg_temp.expect_denied('authenticated',format('SELECT public.medflow_create_doctor_invitation(%L,%L,%L,%L,%L)',
    'x@example.invalid','Synthetic Doctor','Family medicine','Synthetic Clinic',v_hash));

  -- 5. Missing identity.
  PERFORM set_config('request.jwt.claim.sub','',true);
  PERFORM set_config('request.jwt.claims','{}',true);
  PERFORM pg_temp.expect_error('SELECT public.medflow_admin_status()','AUTH_REQUIRED');
  PERFORM pg_temp.expect_error('SELECT public.medflow_admin_list_doctor_invitations()','AUTH_REQUIRED');

  -- 6. Non-admin calling the RPCs directly (outside Express) is refused.
  PERFORM set_config('request.jwt.claim.sub',v_user::text,true);
  IF (public.medflow_admin_status()->>'isAdmin')::boolean THEN RAISE EXCEPTION 'Non-admin reported as admin'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_admin_create_doctor_invitation(%L,%L,%L,%L,%L)',
    'x@example.invalid','Synthetic Doctor','Family medicine','Synthetic Clinic',v_hash),'NOT_ADMIN');
  PERFORM pg_temp.expect_error('SELECT public.medflow_admin_list_doctor_invitations()','NOT_ADMIN');
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_admin_revoke_doctor_invitation(%L)',gen_random_uuid()),'NOT_ADMIN');

  -- 7. Admin: create, list, revoke; responses never expose the token hash.
  PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
  IF NOT (public.medflow_admin_status()->>'isAdmin')::boolean THEN RAISE EXCEPTION 'Admin not recognised'; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_admin_create_doctor_invitation(%L,%L,%L,%L,%L)',
    'not-an-email','Synthetic Doctor','Family medicine','Synthetic Clinic',v_hash),'INVALID_INPUT');
  v_result := public.medflow_admin_create_doctor_invitation(' Synthetic.Doctor@Example.Invalid ','Synthetic Doctor',
    'Family medicine','Synthetic Clinic',v_hash);
  v_invitation := (v_result#>>'{invitation,id}')::uuid;
  IF v_result#>>'{invitation,status}'<>'pending' OR v_result#>>'{invitation,email}'<>'synthetic.doctor@example.invalid' THEN
    RAISE EXCEPTION 'Unexpected created invitation: %',v_result; END IF;
  IF v_result::text ~* 'token|hash|consumed_by' THEN RAISE EXCEPTION 'Create response leaks token data'; END IF;
  v_result := public.medflow_admin_list_doctor_invitations();
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_result->'invitations') e WHERE (e->>'id')::uuid=v_invitation) THEN
    RAISE EXCEPTION 'Created invitation missing from list'; END IF;
  IF v_result::text ~* 'token|hash|consumed_by' THEN RAISE EXCEPTION 'List leaks token data'; END IF;
  v_result := public.medflow_admin_revoke_doctor_invitation(v_invitation);
  IF v_result#>>'{invitation,status}'<>'revoked' THEN RAISE EXCEPTION 'Revoke did not revoke: %',v_result; END IF;
  PERFORM pg_temp.expect_error(format('SELECT public.medflow_admin_revoke_doctor_invitation(%L)',gen_random_uuid()),'NOT_FOUND');

  -- 8. The admin right did not leak into roles, and the non-admin is still not an admin.
  IF EXISTS(SELECT 1 FROM public.platform_admins WHERE user_id=v_user) THEN RAISE EXCEPTION 'Self-promotion detected'; END IF;
  IF (SELECT role FROM public.profiles WHERE id=v_admin)<>'patient' THEN RAISE EXCEPTION 'Admin right changed profiles.role'; END IF;

  RAISE NOTICE 'verify_007_checks: all checks passed';
END $$;
ROLLBACK;
