-- MedFlow platform administrators: invite and revoke doctors from the app.
-- Additive only. Apply as the Supabase migration owner (postgres) after 004-006.
-- The admin right is separate from profiles.role (patient|doctor stays unchanged).
-- Nobody can grant it through the API: only service_role/postgres write platform_admins
-- (see ADMIN_ONBOARDING.md for the one-time onboarding statement).
BEGIN;

CREATE TABLE public.platform_admins (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_admins FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_admins FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.platform_admins TO service_role;

-- Private helper: the caller comes only from the verified JWT (auth.uid()).
CREATE FUNCTION public.medflow_require_admin() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := auth.uid();
BEGIN
  IF v_id IS NULL THEN RAISE EXCEPTION USING MESSAGE='AUTH_REQUIRED', ERRCODE='P0001'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.platform_admins WHERE user_id=v_id) THEN
    RAISE EXCEPTION USING MESSAGE='NOT_ADMIN', ERRCODE='P0001'; END IF;
  RETURN v_id;
END $$;

CREATE FUNCTION public.medflow_admin_invitation_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  -- Never includes token_hash or consumed_by.
  SELECT jsonb_build_object(
    'id',i.id,'email',i.email,'fullName',i.full_name,'specialty',i.specialty,'clinic',i.clinic,
    'status',CASE WHEN i.revoked_at IS NOT NULL THEN 'revoked'
                  WHEN i.consumed_at IS NOT NULL THEN 'accepted'
                  WHEN i.expires_at<=clock_timestamp() THEN 'expired'
                  ELSE 'pending' END,
    'expiresAt',i.expires_at,'acceptedAt',i.consumed_at,'revokedAt',i.revoked_at)
  FROM public.doctor_invitations i WHERE i.id=p_id
$$;

-- Public (authenticated) RPCs. Each one checks the admin right itself, so calling
-- the RPC directly (outside Express) gives exactly the same protection.
CREATE FUNCTION public.medflow_admin_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := auth.uid();
BEGIN
  IF v_id IS NULL THEN RAISE EXCEPTION USING MESSAGE='AUTH_REQUIRED', ERRCODE='P0001'; END IF;
  RETURN jsonb_build_object('isAdmin',EXISTS(SELECT 1 FROM public.platform_admins WHERE user_id=v_id));
END $$;

CREATE FUNCTION public.medflow_admin_create_doctor_invitation(p_email text,p_full_name text,p_specialty text,p_clinic text,p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_created jsonb;
BEGIN
  PERFORM public.medflow_require_admin();
  -- Reuse 004's validation and insert; the raw token never reaches the database.
  v_created := public.medflow_create_doctor_invitation(p_email,p_full_name,p_specialty,p_clinic,p_token_hash);
  RETURN jsonb_build_object('invitation',public.medflow_admin_invitation_json((v_created->>'id')::uuid));
END $$;

CREATE FUNCTION public.medflow_admin_list_doctor_invitations() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.medflow_require_admin();
  RETURN jsonb_build_object('invitations',coalesce((
    SELECT jsonb_agg(public.medflow_admin_invitation_json(i.id) ORDER BY i.expires_at DESC,i.id)
    FROM (SELECT id,expires_at FROM public.doctor_invitations ORDER BY expires_at DESC,id LIMIT 200) i
  ),'[]'::jsonb));
END $$;

CREATE FUNCTION public.medflow_admin_revoke_doctor_invitation(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.medflow_require_admin();
  IF p_id IS NULL THEN RAISE EXCEPTION USING MESSAGE='INVALID_INPUT', ERRCODE='P0001'; END IF;
  -- Revoking blocks the link; an already accepted doctor keeps the role (same as 004).
  PERFORM public.medflow_revoke_doctor_invitation(p_id);
  RETURN jsonb_build_object('invitation',public.medflow_admin_invitation_json(p_id));
END $$;

REVOKE ALL ON FUNCTION public.medflow_require_admin(),public.medflow_admin_invitation_json(uuid),
  public.medflow_admin_status(),public.medflow_admin_create_doctor_invitation(text,text,text,text,text),
  public.medflow_admin_list_doctor_invitations(),public.medflow_admin_revoke_doctor_invitation(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.medflow_admin_status(),
  public.medflow_admin_create_doctor_invitation(text,text,text,text,text),
  public.medflow_admin_list_doctor_invitations(),public.medflow_admin_revoke_doctor_invitation(uuid) TO authenticated;

COMMIT;
