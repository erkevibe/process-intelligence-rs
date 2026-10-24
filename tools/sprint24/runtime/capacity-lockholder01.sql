\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='2s';
SET LOCAL transaction_timeout='10s';
LOCK TABLE public.pi_records IN ACCESS EXCLUSIVE MODE;
SELECT 'LOCK_HOLDER_ACQUIRED';
SELECT pg_sleep(8);
ROLLBACK;
