-- Remove only the fault installed in this new named fixture after rollback proof.
DROP EVENT TRIGGER s11_schema_fault;
DROP FUNCTION public.s11_reject_schema();
