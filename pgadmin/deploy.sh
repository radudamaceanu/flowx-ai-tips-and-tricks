#!/usr/bin/env bash
# Deploy pgAdmin into a FlowX dev env namespace, pre-connected to its Postgres.
#
#   ./deploy.sh <namespace> [--ingress <host>]
#
# Optional env overrides (auto-detected from the Postgres pod when unset):
#   PG_POD=postgresql-0  PG_CONTAINER=postgresql  PG_SERVICE=postgresql  PG_USER=postgres
#   PG_SECRET=<secret>   PG_KEY=<key>             SERVER_NAME="<label in pgAdmin>"
#
# Never prints a password.
set -euo pipefail

NS="${1:?usage: deploy.sh <namespace> [--ingress <host>]}"
shift
HOST=""
if [[ "${1:-}" == "--ingress" ]]; then
  HOST="${2:?--ingress needs a host, e.g. pgadmin-pr3241.dev3.flowxai.dev}"
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
PG_POD="${PG_POD:-postgresql-0}"
PG_CONTAINER="${PG_CONTAINER:-postgresql}"
PG_SERVICE="${PG_SERVICE:-postgresql}"
PG_USER="${PG_USER:-postgres}"
SERVER_NAME="${SERVER_NAME:-Postgres ($NS)}"

# Find the Secret that holds the Postgres superuser password (env POSTGRES_PASSWORD on the pod).
if [[ -z "${PG_SECRET:-}" || -z "${PG_KEY:-}" ]]; then
  ref="$(kubectl -n "$NS" get pod "$PG_POD" -o jsonpath="{.spec.containers[?(@.name==\"$PG_CONTAINER\")].env[?(@.name==\"POSTGRES_PASSWORD\")].valueFrom.secretKeyRef.name}/{.spec.containers[?(@.name==\"$PG_CONTAINER\")].env[?(@.name==\"POSTGRES_PASSWORD\")].valueFrom.secretKeyRef.key}")"
  if [[ "$ref" == "/" ]]; then
    echo "Could not detect the Postgres password secret on $NS/$PG_POD." >&2
    echo "Find it with: kubectl -n $NS get pod $PG_POD -o yaml | grep -B2 -A4 -i password" >&2
    echo "then rerun with PG_SECRET=<secret> PG_KEY=<key> $0 $NS ..." >&2
    exit 1
  fi
  PG_SECRET="${ref%%/*}"
  PG_KEY="${ref#*/}"
fi
echo "Postgres: service $PG_SERVICE, user $PG_USER, password from secret $PG_SECRET/$PG_KEY"

# Login secret: create once with a random password, keep it on redeploys.
if ! kubectl -n "$NS" get secret pgadmin-login >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic pgadmin-login \
    --from-file=password=<(openssl rand -base64 24 | tr -d '/+=\n')
  kubectl -n "$NS" label secret pgadmin-login app=pgadmin
fi

render() {
  sed -e "s|__SERVER_NAME__|$SERVER_NAME|g" \
      -e "s|__PG_SERVICE__|$PG_SERVICE|g" \
      -e "s|__PG_USER__|$PG_USER|g" \
      -e "s|__PG_SECRET__|$PG_SECRET|g" \
      -e "s|__PG_KEY__|$PG_KEY|g" \
      -e "s|__HOST__|$HOST|g" "$1"
}

render "$DIR/pgadmin.yaml" | kubectl -n "$NS" apply -f -
if [[ -n "$HOST" ]]; then
  render "$DIR/ingress.yaml" | kubectl -n "$NS" apply -f -
fi
kubectl -n "$NS" rollout status deploy/pgadmin --timeout=300s

echo
if [[ -n "$HOST" ]]; then
  echo "Open: https://$HOST"
else
  echo "Open: kubectl -n $NS port-forward svc/pgadmin 8080:8080  ->  http://localhost:8080"
fi
echo "Login: admin@flowx.ai / password:"
echo "  kubectl -n $NS get secret pgadmin-login -o jsonpath='{.data.password}' | base64 -d; echo"
