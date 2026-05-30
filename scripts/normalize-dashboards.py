#!/usr/bin/env python3
"""Normalize Grafana dashboard exports and guard the provisioning config.

Two jobs, dispatched by path:

1. Dashboards under grafana/dashboards/*.json
   A v2 "Dashboard" export from the Grafana UI carries server-managed metadata
   (uid, resourceVersion, generation, creationTimestamp, namespace, and the
   grafana.app/* labels/annotations). None of it belongs in version control: it
   churns diffs and can confuse the provisioner. We keep only apiVersion, kind,
   metadata.name (the stable provisioning identity) and spec. Classic (non-v2)
   dashboards are left untouched beyond a JSON validity check.

2. Provider configs under grafana/provisioning/dashboards/*.yaml
   These must be Grafana dashboard *provider* configs (apiVersion: 1 + a
   providers list), never a dashboard. A dashboard saved here crash-loops
   Grafana on its next restart, so we fail the commit loudly instead.

Exit non-zero if a file was rewritten (so the user re-stages it) or if a
provider config is invalid. Safe to run by hand: with no args it scans the
known paths.
"""

import glob
import json
import sys

try:
    import yaml
except ImportError:
    yaml = None

DASH_GLOB = "phase02/observer/grafana/dashboards/*.json"
PROV_GLOB = "phase02/observer/grafana/provisioning/dashboards/*.y*ml"


def is_dashboard_path(path):
    return "/grafana/dashboards/" in path and path.endswith(".json")


def is_provider_path(path):
    return "/grafana/provisioning/dashboards/" in path and (
        path.endswith(".yaml") or path.endswith(".yml")
    )


def normalize_dashboard(path):
    """Strip server-managed metadata from a v2 dashboard. Returns True if the
    file was changed."""
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    try:
        doc = json.loads(original)
    except json.JSONDecodeError as exc:
        print("ERROR %s: invalid JSON: %s" % (path, exc), file=sys.stderr)
        raise SystemExit(1)

    # Only the v2 resource format carries the noisy metadata. Leave classic
    # dashboards (no dashboard.grafana.app kind) exactly as they are.
    kind = doc.get("kind")
    api = str(doc.get("apiVersion", ""))
    if kind != "Dashboard" or not api.startswith("dashboard.grafana.app"):
        return False

    name = doc.get("metadata", {}).get("name")
    if not name:
        print("ERROR %s: v2 dashboard has no metadata.name" % path,
              file=sys.stderr)
        raise SystemExit(1)

    clean = {
        "apiVersion": doc["apiVersion"],
        "kind": doc["kind"],
        "metadata": {"name": name},
        "spec": doc["spec"],
    }
    rendered = json.dumps(clean, indent=2, ensure_ascii=False) + "\n"
    if rendered != original:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(rendered)
        return True
    return False


def check_provider(path):
    """Fail if a provisioning config is not a provider config (or is a
    dashboard in disguise)."""
    if yaml is None:
        print("ERROR: PyYAML not available to validate %s" % path,
              file=sys.stderr)
        raise SystemExit(1)
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        print("ERROR %s: invalid YAML: %s" % (path, exc), file=sys.stderr)
        raise SystemExit(1)

    looks_like_dashboard = isinstance(doc, dict) and (
        doc.get("kind") == "Dashboard" or "spec" in doc or "panels" in doc
    )
    if looks_like_dashboard:
        print("ERROR %s: this is a DASHBOARD, not a provider config. A "
              "dashboard here crash-loops Grafana. Move it to "
              "grafana/dashboards/<name>.json." % path, file=sys.stderr)
        raise SystemExit(1)

    ok = (
        isinstance(doc, dict)
        and str(doc.get("apiVersion")) == "1"
        and isinstance(doc.get("providers"), list)
        and len(doc["providers"]) > 0
    )
    if not ok:
        print("ERROR %s: not a valid dashboard provider config (need "
              "apiVersion: 1 and a non-empty providers list)." % path,
              file=sys.stderr)
        raise SystemExit(1)


def main(argv):
    paths = argv[1:]
    if not paths:
        paths = glob.glob(DASH_GLOB) + glob.glob(PROV_GLOB)

    changed = []
    for path in paths:
        if is_dashboard_path(path):
            if normalize_dashboard(path):
                changed.append(path)
        elif is_provider_path(path):
            check_provider(path)

    if changed:
        for path in changed:
            print("normalized (re-stage it): %s" % path, file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv)
