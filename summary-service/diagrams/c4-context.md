# C4 — System Context

The Summary Service in the YCare HMS landscape.

```mermaid
C4Context
    title System Context: Summary Service in YCare HMS

    Person(admin, "Hospital Admin", "Views consultation-fee summary and updates invoice statuses")
    Person(doctor, "Doctor", "Triggers OPD invoice creation indirectly via the HMS")
    Person(op_staff, "OPD Counter Staff", "Generates OPD invoices at the counter")

    System(ycare_hms, "YCare HMS (Next.js)", "Patient registration, OPD visits, invoicing, EMR. The existing monolith.")
    System(summary, "Summary Service", "Consultation Fees Invoice lifecycle and admin summary dashboard")
    SystemDb_Ext(postgres, "PostgreSQL (shared)", "Existing HMS database; new tables added for CFI")
    SystemDb_Ext(redis, "Redis", "New; local-only aggregate counter cache")

    Rel(admin, ycare_hms, "Views summary, updates status", "HTTPS / browser")
    Rel(doctor, ycare_hms, "Uses OPD workflow", "HTTPS / browser")
    Rel(op_staff, ycare_hms, "Generates OPD invoice", "HTTPS / browser")

    Rel(ycare_hms, summary, "Submits outbox events; reads summary; updates status", "HTTP / 127.0.0.1:4000 (no auth in v1)")

    Rel(summary, postgres, "Reads/writes CFI rows, status, adjustments, outbox", "TCP 5432")
    Rel(summary, redis, "Reads/writes aggregate counters", "TCP 6379 / 127.0.0.1")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Key relationships

- **Admin** interacts only with the HMS; the HMS proxies to the Summary Service. The admin never talks to the Summary Service directly.
- **OPD staff** generates OPD invoices in the HMS. The Summary Service does not see the staff directly — it only sees the resulting outbox events in the DB.
- The **HMS → Summary Service** link is the only call surface. It is local (127.0.0.1:4000). v1 has no service-to-service auth; trust relies on the localhost bind. Auth is a v2 follow-up.
- **PostgreSQL** is shared between HMS and Summary Service. Both write to the same DB, in different tables.
- **Redis** is new, local-only, used only by the Summary Service.

## What's NOT in the picture

- No internet. The hospital server is on a private network.
- No external service dependencies. No cloud, no SaaS, no notification provider.
- No patient-facing touchpoint. The admin UI is the only UI.
