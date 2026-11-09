#!/usr/bin/env bash
# Remove pgAdmin from a namespace. Touches only objects labelled app=pgadmin.
#
#   ./remove.sh <namespace>            # everything (incl. the login secret)
#   ./remove.sh <namespace> --ingress  # only the public URL
set -euo pipefail

NS="${1:?usage: remove.sh <namespace> [--ingress]}"
if [[ "${2:-}" == "--ingress" ]]; then
  kubectl -n "$NS" delete ingress -l app=pgadmin
else
  kubectl -n "$NS" delete deploy,svc,configmap,secret,ingress -l app=pgadmin
fi
