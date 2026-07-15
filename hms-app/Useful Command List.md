
```sh
set -a && source load-tests/.env.test && set +a && npx tsx load-tests/scripts/seed-verify.ts
```

#hms-app #commands #load-testing
[[hms-app/load-testing/spec|See load-testing spec]]

```bash
set -a && source load-tests/.env.test && set +a && RUN_TS=$(date -u +%Y%m%dT%H%M%SZ) && SCENARIO=load && echo "RUN_TS=$RUN_TS BASE_URL=$BASE_URL" && k6 run
      load-tests/scenarios/load.js --out json=load-tests/reports/load-${RUN_TS}.json --summary-trend-stats="avg,p(50),p(90),p(95),p(99)" 2>&1 | tail -120
```