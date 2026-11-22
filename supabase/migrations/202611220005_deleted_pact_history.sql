BEGIN;

ALTER TABLE public.pacts DROP CONSTRAINT pacts_status_check;
ALTER TABLE public.pacts ADD CONSTRAINT pacts_status_check
  CHECK (status IN ('awaiting_acceptance','active','under_verification',
    'completed','breached','declined','deleted'));

ALTER TABLE public.pact_activities DROP CONSTRAINT pact_activities_activity_type_check;
ALTER TABLE public.pact_activities ADD CONSTRAINT pact_activities_activity_type_check
  CHECK (activity_type IN ('created','edited','deleted','invited','accepted','declined','activated',
    'evidence_submitted','evidence_approved','evidence_rejected','completed','breached','ban_started','ban_ended'));

CREATE OR REPLACE FUNCTION public.hellbound_delete_pact(pact uuid, expected_revision integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM hellbound_private.lock_pending_pact(pact, expected_revision);
  UPDATE public.pacts SET status='deleted' WHERE id=pact;
  DELETE FROM public.notifications WHERE pact_id=pact AND type='invitation';
  PERFORM hellbound_private.event(pact,'deleted','Creator deleted the pact');
END; $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
