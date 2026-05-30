# Architecture

![Architecture](architecture.drawio.png)

## Flow summary

- **User to Caddy (:80):** all application traffic. `/` is proxied to the
  frontend, `/backend/*` to the backend (prefix stripped). The app containers
  publish only to host loopback (127.0.0.1), never the public internet.
- **User to Grafana (:3000):** dashboards and the alerting view.
- **Alloy to Mimir (:9009):** all metrics (caddy, frontend, backend, node,
  cadvisor) via Prometheus `remote_write`. Frontend and backend run the same
  image and are separated by the scrape `job` label.
- **Alloy to Loki (:3100):** all Docker container logs.
- **Mimir ruler to Alertmanager to ntfy:** alerts evaluated in Mimir, routed by
  the embedded Alertmanager to the ntfy.sh topic.

Server-to-server metric and log traffic stays on private IPs inside the VPC
(same AZ), so there is no cross-AZ transfer cost and Mimir/Loki are never
exposed to the public internet.
