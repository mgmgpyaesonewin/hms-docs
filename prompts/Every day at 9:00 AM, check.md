Every day at 9:00 AM, check

#monitoring #health-check #prompts

Related: [[INDEX]] · [[prompts/README]] 

- https://hms-dev.y-care.app/healthz/ready
- http://hms-uat.dmh-hospital.net/healthz/ready

Treat HTTP 2xx or 3xx as healthy. Stay silent when healthy, but notify me on Telegram if it is 
unreachable or returns another status.

Health Check Monitoring — Prompt
Every day at 9:00 AM (Asia/Singapore), perform an HTTP GET request against each of the following endpoints, with a timeout of 10 seconds per request:

https://hms-dev.y-care.app/healthz/ready
http://hms-uat.dmh-hospital.net/healthz/ready

Health criteria:

Treat any HTTP response with status code in the 2xx or 3xx range as healthy.
Treat any of the following as unhealthy:

Connection timeout or unreachable host (DNS failure, connection refused, timeout)
HTTP status code in the 4xx or 5xx range
Any other network-level error



Retry logic:

On failure, retry up to 3 times with exponential backoff before declaring the endpoint unhealthy:

Retry 1: wait 5 seconds
Retry 2: wait 10 seconds
Retry 3: wait 20 seconds


Only send a notification if all 3 retries fail.

Notification behavior:

If all endpoints are healthy, stay silent — do not send any Telegram message.
If any endpoint is unhealthy after exhausting all retries, send a Telegram message that includes:

The endpoint URL that failed
The failure reason (status code, or "unreachable"/timeout) — ideally noting the reason from the final retry attempt
The number of attempts made (should be 4 total: 1 initial + 3 retries)
The timestamp of the check (in Asia/Singapore time)


If multiple endpoints fail, send a single consolidated message listing all failures rather than one message per endpoint.

Check each endpoint independently — a failure/retry cycle on one should not block or delay the check on the other (run checks concurrently, not sequentially).
