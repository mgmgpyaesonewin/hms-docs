# ADR 0010: Search strategy — `pg_trgm` substring match on Invoice No

- **Status:** Accepted (revised)
- **Section in brief:** 7.9

## Context

The summary list page has a search box. Search is **not** free text — it is restricted to matching against exactly one column: `consultation_fees_invoices.invoice_no`. (Doctor name is a display column and a `doctorId` filter, but is **not** substring-searchable; patient name is displayed in the list and is also **not** searchable.)

**Why invoice number only?** Admins arrive at the summary page with one of two things in hand: a printed/paid invoice number from a patient, or a list view they want to filter by date/counter/doctor/status. Invoice number is the unique, stable, audit-friendly identifier; doctor lookup is already covered by the `doctorId` filter dropdown. Free-text search across doctor names adds no value that the filter set doesn't already cover, and excludes the privacy/durability concerns of patient name lookup (handled by the HMS's existing patient search).

**On `invoice_no`:** the column on the CFI is the **patient-direct invoice number** of the parent — the OPD **or** IPD invoice number printed on the bill the patient sees and pays. The CFI itself has no separate invoice number — it is a derived tracking record identified by the parent's invoice number + tenant. The search is defined as: "OPD or IPD invoice number" — the same column, the same index, the same substring query, regardless of whether the parent is OPD or IPD. **v1 caveat:** only OPD invoices create CFIs, so searching an IPD invoice number returns zero results in v1. When IPD support is added in v2+, the same `invoice_no` column carries the IPD invoice number and the search works unchanged.

Search semantics: case-insensitive substring match. An admin types "0042" and the query matches any invoice number containing "0042" (e.g. "INV-2026-0042-JOHNSMITH").

The search must be fast (sub-second on ~100k rows) and integrate cleanly with the existing filter set (date, counter, doctor, status).

## Options considered

- **(a) `pg_trgm` GIN index on `lower(invoice_no)`** — substring match, fast, no new infra. Standard Postgres extension.
- **(b) Postgres FTS with `tsvector` + GIN index** — what an earlier version of this ADR specified. Heavier, requires a generated column, brings stemming/tokenization for what is now a single-field substring search.
- **(c) Simple `ILIKE` without trigram index** — works on small tables; on 100k+ rows it does a sequential scan. Rejected.
- **(d) External search (Meilisearch / Elasticsearch)** — overkill for v1.

## Decision

**(a) `pg_trgm` GIN index on `lower(invoice_no)`.** Replace the FTS design from the previous version of this ADR. Doctor name was previously in the search set; it is no longer (the `doctorId` filter covers doctor lookup; doctor name remains a denormalized display column).

## Schema

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- GIN trigram index on the lowercased invoice number.
-- Substring match (LIKE '%foo%') is index-accelerated by this.
CREATE INDEX idx_cfi_invoice_no_trgm
    ON consultation_fees_invoices USING GIN (lower(invoice_no) gin_trgm_ops);
```

No generated column. No `tsvector`. One GIN index.

## Query

```sql
SELECT *
FROM consultation_fees_invoices
WHERE tenant_id = $1
  AND billing_date BETWEEN $from AND $to
  AND lower(invoice_no) LIKE '%' || lower($search) || '%'
  -- ... other filters ...
ORDER BY billing_date DESC
LIMIT 25;
```

The `lower(invoice_no) LIKE '%' || lower($search) || '%'` is index-accelerated by the trigram GIN index for queries of 3+ characters. For shorter queries (1-2 chars), Postgres falls back to a sequential scan on that small substring space; the existing `(tenant_id, billing_date DESC)` index keeps the row read bounded.

The result is unordered by relevance — it's a substring match, not a ranked search. This is intentional: an admin looking for a specific invoice expects to find it; relevance ranking of a single-field substring match is not meaningful.

## Rationale

- **Right-sized to the problem.** Substring match on 1 column is exactly what `pg_trgm` is for. FTS would add tokenization, stemming, and ranking machinery that we don't use.
- **No new infrastructure.** `pg_trgm` ships with Postgres; the extension just needs to be enabled in the migration.
- **No generated column.** The previous FTS design required a `search_vector tsvector GENERATED ALWAYS AS (...) STORED` column maintained by the DB on every row. The trigram index computes trigrams at index time and doesn't need a stored column.
- **Predictable for admins.** "Type '0042' → see invoices with '0042' anywhere" is what an admin expects. FTS's tokenization can produce surprising matches that aren't useful for this use case.
- **Privacy.** Patient name is intentionally excluded from the searchable set. Doctor name is excluded because the `doctorId` filter is the natural lookup. Patient name lookup is a separate concern handled by the HMS's existing patient search.

## Consequences

- **Schema change:** the previous `search_vector` generated column, the `idx_cfi_search` GIN index, and the `idx_cfi_doctor_name_trgm` trigram GIN index are removed; only the `idx_cfi_invoice_no_trgm` trigram GIN index remains. The migration script applies the change idempotently.
- **Doctor name and patient name are no longer substring-searchable.** The brief's Section 3.6 and the OpenAPI spec's `search` parameter description reflect this. The UI's search box should be labeled "Search by Invoice No" so admins know the scope. Doctor lookup goes through the `doctorId` filter; patient lookup goes through the HMS.
- **Search ranking is by billing_date DESC, not by relevance.** This is a deliberate design choice — see Rationale.
- **No change to the existing `(tenant_id, billing_date DESC)` index.** It still drives the sort and the date-range filter.
- **No change to the CFI's denormalized fields.** `patient_name`, `doctor_name`, `counter_name`, `invoice_no` are still denormalized for display; only the search semantics changed.

## When to revisit

- If the hospital later wants relevance-ranked search across multiple fields (e.g., a fuzzy "find anything related to this patient" search), add a separate FTS index on the same columns and union the two queries. v1 stays simple.
- If admin feedback is that 1-2 character prefixes should match (e.g., typing "IV" to find "INV"), the current trigram GIN already covers this for 3+ chars; 1-2 chars will be a sequential scan on a small filter set. If the filter is large (10k+ rows after the date range), add a btree on `lower(invoice_no) text_pattern_ops` for prefix `LIKE 'foo%'` acceleration. Out of scope for v1.

## Related

- [[data-model/schema|data-model/schema.sql]]
- Section 3.6 in the brief
- [[0009-redis-cache-model|ADR 0009]] (Redis cache model — search is a Postgres-only filter; Redis does not accelerate it)
- `api/openapi.yaml` (the `search` query parameter)
