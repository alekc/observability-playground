# observability-demo app

A small, production-style Go HTTP service whose sole purpose is to generate
realistic **metrics**, **logs**, and **load patterns** for the observability
stack (Grafana Alloy → Mimir + Loki → Grafana).

It is not a real business application. Every endpoint is designed to exercise a
specific signal or alert rule so the dashboards and alerting rules can be
demonstrated end-to-end.

---

## Endpoints

| Method | Path       | What it does                                                                                                                          |
|--------|------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `GET`  | `/`        | Returns `{"service":"project-observability-app","message":"ok"}`. Unknown paths get a 404.                                            |
| `GET`  | `/health`  | Returns `{"status":"healthy"}`. Used by the load-balancer / Caddy health check.                                                       |
| `GET`  | `/slow`    | Sleeps a random 50–1000 ms before responding. Drives `app_request_duration_seconds` and the **SlowResponseTime** alert.               |
| `GET`  | `/error`   | Always returns HTTP 500. Drives `app_errors_total` and the **HighErrorRate** alert.                                                   |
| `GET`  | `/cpu`     | Burns CPU on all cores for `?seconds=` (default 30, max 600). Drives the **HighCPUUsage** alert.                                      |
| `GET`  | `/mem`     | Allocates `?mb=` MB (default 420, max 480) and holds it for `?seconds=` (default 150, max 600). Drives the **HighMemoryUsage** alert. |
| `GET`  | `/metrics` | Prometheus text exposition (scraped by Grafana Alloy). Not instrumented itself so scrape traffic stays out of request metrics.        |

---

## Prometheus metrics

| Metric                         | Type      | Labels                     |
|--------------------------------|-----------|----------------------------|
| `app_requests_total`           | Counter   | `method`, `path`, `status` |
| `app_request_duration_seconds` | Histogram | `method`, `path`           |
| `app_errors_total`             | Counter   | `path`                     |
| `app_active_requests`          | Gauge     | —                          |

---

## Structured logging

Every request emits a JSON log line to stdout via `log/slog`:

```json
{
  "time": "…",
  "level": "INFO",
  "msg": "request handled",
  "method": "GET",
  "path": "/",
  "status": 200,
  "duration_ms": 0.42,
  "remote_addr": "…"
}
```

Errors (`5xx`) are logged at `ERROR` level. Grafana Alloy ships these logs to
Loki where they can be queried with LogQL.

---

## Environment variables

| Variable          | Default | Description                           |
|-------------------|---------|---------------------------------------|
| `APP_LISTEN_ADDR` | `:8080` | TCP address the HTTP server binds to. |

---

## Building

### Local

```bash
go build -o app .
./app
```

### Multi-platform Docker image

```bash
# defaults: al3kc/observability-demo:v0.0.1
./build-and-publish.sh

# override image / tag
DEST_IMAGE=ghcr.io/your-org/observability-demo TAG=v1.2.3 ./build-and-publish.sh
```

`build-and-publish.sh` automatically creates a `docker-container` buildx
builder (`observability-multiarch`) the first time it runs, which is required
for `linux/amd64,linux/arm64` multi-platform builds. The built image is pushed
directly to the registry (no local load).

---

## Triggering alerts

| Alert                | How                                                         |
|----------------------|-------------------------------------------------------------|
| **HighErrorRate**    | `while true; do curl -s http://HOST/error >/dev/null; done` |
| **SlowResponseTime** | `while true; do curl -s http://HOST/slow >/dev/null; done`  |
| **HighCPUUsage**     | `curl "http://HOST/cpu?seconds=600"`                        |
| **HighMemoryUsage**  | `curl "http://HOST/mem?mb=420&seconds=300"`                 |
