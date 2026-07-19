  \c ycare_hms_dev

  Then paste this once — it uses now() - interval '1 day' as the cutoff so "yesterday" stays relative (no date math needed next time):

  CREATE SCHEMA IF NOT EXISTS scratch;
  DROP TABLE IF EXISTS scratch.growth;
  CREATE TABLE scratch.growth (table_name text, rows_since bigint);

  DO $$
  DECLARE
    r record;
    cnt bigint;
    cutoff constant timestamp := date_trunc('day', now() - interval '1 day');
  BEGIN
    FOR r IN
      SELECT c.table_schema, c.table_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema=c.table_schema AND t.table_name=c.table_name
      WHERE c.table_schema='public'
        AND t.table_type='BASE TABLE'
        AND c.column_name='created_at'
        AND c.data_type IN ('timestamp without time zone','timestamp with time zone')
    LOOP
      EXECUTE format(
        'SELECT count(*) FROM %I.%I WHERE created_at >= %L',
        r.table_schema, r.table_name, cutoff)
        INTO cnt;
      IF cnt IS NOT NULL AND cnt > 0 THEN
        EXECUTE format(
          'INSERT INTO scratch.growth VALUES (%L, %L)',
          r.table_schema||'.'||r.table_name, cnt);
      END IF;
    END LOOP;
  END $$;

  SELECT table_name, rows_since
  FROM scratch.growth
  ORDER BY rows_since DESC, table_name
  LIMIT 10;

  DROP TABLE scratch.growth;
  DROP SCHEMA scratch;

15-jul
             table_name             | rows_since 
------------------------------------+------------
 public.doctor_timeslots            |       9975
 public.permissions                 |       1595
 public.lab_service_audits          |       1062
 public.service_bills               |        204
 public.appointments                |        193
 public.opd_billing_payment_methods |        183
 public.bills                       |        182
 public.opd_billings                |        182
 public.service_package_bills       |        182
 public.patients                    |        175


16-jul
             table_name             | rows_since 
------------------------------------+------------
 public.lab_service_audits          |       2259
 public.doctor_timeslots            |       1995
 public.permissions                 |        895
 public.lab_services                |        343
 public.appointments                |        202
 public.service_bills               |        199
 public.lab_service_items           |        194
 public.bills                       |        174
 public.opd_billing_payment_methods |        174
 public.opd_billings                |        174
 public.service_package_bills       |        174
 public.appointment_services        |        173
 public.patients                    |        165
 public.proxy_bills                 |        108
 public.procedure_bills             |        107
 public.imaging_services            |         93
 public.referrals                   |         66
 public.lab_pivots                  |         63
 public.imaging_lists               |         51
 public.store_mappings              |         30 