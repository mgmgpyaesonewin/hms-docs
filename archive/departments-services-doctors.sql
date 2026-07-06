-- departments-services-doctors.sql
-- Produces one row per (department, service, doctor) plus one row per
-- service with no doctor mapping (doctor columns NULL). Run inside the pod.
--
-- Two ways to use this file:
--
-- 1. From a psql shell (recommended — writes a file inside the pod):
--      \copy (
--        -- paste the SELECT below, OR
--      ) TO '/tmp/departments-services-doctors.csv' WITH (FORMAT csv, HEADER true)
--
-- 2. One-shot from any shell that has psql + DATABASE_URL:
--      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -A -F',' -P null='\N' \
--        -c "$(cat departments-services-doctors.sql)" \
--        > /tmp/departments-services-doctors.csv
--    (Add -q for quiet, drop the header line by removing WITH HEADER.)

SELECT
  d.department_code,
  d.name                                       AS department_name,
  s.service_id,
  s.name                                       AS service_name,
  sc.name                                      AS category,
  ssc.name                                     AS sub_category,
  s.status::text                               AS service_status,
  s.service_price::text                        AS service_price,
  doc.doctor_id,
  doc.title,
  u.full_name                                  AS doctor_name,
  sp.name                                      AS specialization,
  u.email                                      AS doctor_email,
  u.phone_no                                   AS doctor_phone,
  ds.service_price::text                       AS doctor_service_price,
  ds.first_round_price::text                   AS first_round_price,
  ds.urgent_price::text                        AS urgent_price,
  doc."medicalLicenseNumber"                   AS medical_license_number
FROM departments d
LEFT JOIN services              s   ON s.department_id       = d.id
LEFT JOIN service_categories    sc  ON sc.id                 = s.category_id
LEFT JOIN service_sub_categories ssc ON ssc.id               = s.sub_category_id
LEFT JOIN "DoctorService"       ds  ON ds."serviceId"        = s.id
LEFT JOIN doctors               doc ON doc.id                = ds."doctorId"
LEFT JOIN users                 u   ON u.id                  = doc.user_id
LEFT JOIN specializations       sp  ON sp.id                 = doc.specialization_id
ORDER BY d.department_code, s.service_id, u.full_name NULLS LAST
;