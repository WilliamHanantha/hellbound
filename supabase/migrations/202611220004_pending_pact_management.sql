BEGIN;

ALTER TABLE public.pacts ADD COLUMN revision integer NOT NULL DEFAULT 0;
ALTER TABLE public.pact_activities DROP CONSTRAINT pact_activities_activity_type_check;
ALTER TABLE public.pact_activities ADD CONSTRAINT pact_activities_activity_type_check
  CHECK (activity_type IN ('created','edited','invited','accepted','declined','activated',
    'evidence_submitted','evidence_approved','evidence_rejected','completed','breached','ban_started','ban_ended'));

CREATE FUNCTION hellbound_private.lock_pending_pact(pact uuid, expected_revision integer)
RETURNS public.pacts LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE current_pact public.pacts;
BEGIN
  SELECT * INTO current_pact FROM public.pacts WHERE id=pact FOR UPDATE;
  IF NOT FOUND OR auth.uid() IS NULL OR current_pact.creator_id <> auth.uid()
     OR current_pact.status <> 'awaiting_acceptance' THEN
    RAISE EXCEPTION 'Only the creator can manage a pending pact';
  END IF;
  IF current_pact.revision IS DISTINCT FROM expected_revision THEN
    RAISE EXCEPTION 'Pact changed. Refresh and try again';
  END IF;
  RETURN current_pact;
END; $$;

CREATE FUNCTION public.hellbound_edit_pact(pact uuid, expected_revision integer, payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  current_pact public.pacts;
  responsible uuid;
  verifier uuid := (payload->>'verifier_id')::uuid;
  witnesses uuid[];
BEGIN
  current_pact := hellbound_private.lock_pending_pact(pact, expected_revision);
  SELECT user_id INTO STRICT responsible FROM public.pact_members
    WHERE pact_id=pact AND role='responsible';
  IF verifier IS NULL OR responsible=verifier THEN
    RAISE EXCEPTION 'Choose a different verifier';
  END IF;
  IF (payload->>'deadline')::timestamptz <= now() THEN
    RAISE EXCEPTION 'Deadline must be in the future';
  END IF;
  witnesses := ARRAY(SELECT value::uuid
    FROM jsonb_array_elements_text(coalesce(payload->'witness_ids','[]'::jsonb)));
  UPDATE public.pacts SET
    title=payload->>'title', description=payload->>'description',
    deadline=(payload->>'deadline')::timestamptz,
    evidence_type=payload->>'evidence_type', evidence_requirement=payload->>'evidence_requirement',
    consequence_type=payload->>'consequence_type', consequence_detail=payload->>'consequence_detail',
    announcement_audience=payload->>'announcement_audience', revision=current_pact.revision+1
  WHERE id=pact;

  DELETE FROM public.notifications WHERE pact_id=pact AND type='invitation';
  DELETE FROM public.pact_members WHERE pact_id=pact;
  INSERT INTO public.pact_members(pact_id,user_id,role)
    VALUES(pact,responsible,'responsible'),(pact,verifier,'verifier');
  INSERT INTO public.pact_members(pact_id,user_id,role)
    SELECT pact,witness,'witness' FROM unnest(witnesses) AS witness;
  UPDATE public.pact_members SET acceptance_status='accepted',responded_at=now()
    WHERE pact_id=pact AND user_id=auth.uid();

  PERFORM hellbound_private.event(pact,'edited','Pact edited. Participants need to accept again');
  INSERT INTO public.notifications(user_id,pact_id,type,message)
    SELECT user_id,pact,'invitation','Pact updated. Review and respond: '||(payload->>'title')
    FROM public.pact_members JOIN public.user_settings USING(user_id)
    WHERE pact_id=pact AND acceptance_status='pending' AND pact_invitations;
  RETURN pact;
END; $$;

CREATE FUNCTION public.hellbound_delete_pact(pact uuid, expected_revision integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM hellbound_private.lock_pending_pact(pact, expected_revision);
  DELETE FROM public.pacts WHERE id=pact;
END; $$;

CREATE FUNCTION public.hellbound_respond(pact uuid, accept boolean, expected_revision integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.pacts;
BEGIN
 IF auth.uid() IS NULL OR accept IS NULL THEN RAISE EXCEPTION 'Invalid response'; END IF;
 SELECT * INTO v FROM public.pacts WHERE id=pact FOR UPDATE;
 IF NOT FOUND OR v.status <> 'awaiting_acceptance' THEN RAISE EXCEPTION 'Pact is no longer awaiting acceptance'; END IF;
 IF v.revision IS DISTINCT FROM expected_revision THEN RAISE EXCEPTION 'Pact changed. Refresh before responding'; END IF;
 IF v.deadline <= now() THEN RAISE EXCEPTION 'Deadline already passed'; END IF;
 UPDATE public.pact_members SET acceptance_status=CASE WHEN accept THEN 'accepted' ELSE 'declined' END,responded_at=now()
 WHERE pact_id=pact AND user_id=auth.uid() AND acceptance_status='pending';
 IF NOT FOUND THEN RAISE EXCEPTION 'No pending invitation for this account'; END IF;
 PERFORM hellbound_private.event(pact,CASE WHEN accept THEN 'accepted' ELSE 'declined' END,CASE WHEN accept THEN 'Invitation accepted' ELSE 'Invitation declined' END);
 IF NOT accept THEN UPDATE public.pacts SET status='declined' WHERE id=pact;
 ELSIF NOT EXISTS(SELECT 1 FROM public.pact_members WHERE pact_id=pact AND acceptance_status<>'accepted') THEN
 UPDATE public.pacts SET status='active' WHERE id=pact;
 PERFORM hellbound_private.event(pact,'activated','All participants accepted. Pact activated');
 END IF;
END; $$;

-- Older clients can respond to unedited pacts only.
CREATE OR REPLACE FUNCTION public.hellbound_respond(pact uuid, accept boolean)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.hellbound_respond(pact, accept, 0);
$$;

REVOKE ALL ON FUNCTION hellbound_private.lock_pending_pact(uuid,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.hellbound_edit_pact(uuid,integer,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.hellbound_delete_pact(uuid,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.hellbound_respond(uuid,boolean,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hellbound_edit_pact(uuid,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hellbound_delete_pact(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hellbound_respond(uuid,boolean,integer) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
