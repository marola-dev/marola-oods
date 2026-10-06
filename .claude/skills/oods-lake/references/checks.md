# checks.sql is a gate

The iron rule and the rationalizations table are adapted from dbt-labs/dbt-agent-skills
`troubleshooting-dbt-job-errors` (Apache-2.0; [NOTICE.md](../NOTICE.md)); the rest is in-house.

`specs/001-beach-persistence/contracts/checks.sql` holds the store's acceptance checks: the views'
behaviour (US1, US3, US4) and FR-017, what `oods check` refuses before a batch commits (duplicate
keys, values outside a vocabulary, a count without a unit, a bad UF or IBGE code, coordinates
outside Brazil). Any failed check stops with its message.

```bash
cd specs/001-beach-persistence/contracts && duckdb -bail :memory: < checks.sql   # "checks: all passed"
scripts/lake-migrate.sh --self-test                                              # also runs it inside a migrated lake
```

## The iron rule

**Never weaken a check to make it pass.** A failing check is evidence: about the data, a view, or
an adapter. Changing the check, its fixture or its vocabulary to go green hides the problem. Find
the rows and the cause first; the fix goes where the cause is.

| You're thinking | Reality |
|---|---|
| "Just add the value to the vocabulary" | Is it a real new agency label, or a parser bug? Show the rows and ask. |
| "Widen the bounding box a little" | A point outside Brazil is usually a swapped lat/lon. Find it. |
| "Drop the duplicate-key check, the view dedups anyway" | `sample_dedup` dedups channels, not a key the ETL wrote twice. |
| "The fixture is wrong, update the expected ratio" | Change a fixture only with the spec line that says the new value. |
| "It's flaky" | The checks are deterministic SQL. Something changed. |
| "The run must land today" | A failed `oods check` commits nothing; the lake keeps its last good snapshot. |

A check changes only when the spec changes, in the same PR, and the PR says why.

## Find the rows behind an FR-017 failure

The same predicates as `checks.sql`, returning the offending rows instead of an error:

```sql
SELECT source_id, point_key, count(*) AS copies
FROM point GROUP BY ALL HAVING count(*) > 1;
```

```sql
SELECT source_id, point_key, sampled_on, sampled_at, channel, count(*) AS copies
FROM sample GROUP BY ALL HAVING count(*) > 1;
```

```sql
SELECT source_id, point_key, sampled_on, condition, indicator, indicator_qualifier, channel
FROM sample
WHERE condition NOT IN ('propria', 'impropria', 'unknown')
   OR indicator NOT IN ('e_coli', 'enterococci', 'thermotolerant_coliforms', 'unknown')
   OR indicator_qualifier NOT IN ('exact', 'below', 'above')
   OR channel NOT IN ('csv', 'pdf', 'json', 'arcgis', 'powerbi', 'kmz', 'html');
```

```sql
SELECT source_id, point_key, lat, lon FROM point
WHERE lat IS NOT NULL AND NOT (lat BETWEEN -34.0 AND 5.5 AND lon BETWEEN -74.1 AND -28.6);
```

Then: which snapshot brought them in (`table_changes`, [inspect.md](inspect.md)), which job
(`fetch_run.snapshot_id`), and whether the fix is the adapter (marola-app), the view
(`views.sql`, a PR here), or a restore ([recovery.md](recovery.md)).
