-- Fail inside the first transactional v2 CREATE TABLE; owned new fixture only.
CREATE FUNCTION public.s11_reject_schema() RETURNS event_trigger LANGUAGE plpgsql
AS $$BEGIN RAISE EXCEPTION 'sprint11 owned migration DDL fault'; END$$;
CREATE EVENT TRIGGER s11_schema_fault ON ddl_command_end WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION public.s11_reject_schema();
