#!/usr/bin/env bash
set -Eeuo pipefail

DELIVERY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-swordhealth-prod-eks}"
APPLICATION_NAMESPACE="swordhealth"
ARGOCD_CHART_VERSION="10.11.6"

for tool in helm kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 2
  fi
done

if [[ ! -f "$DELIVERY_DIR/argocd/root-app.yaml" ]]; then
  printf 'Argo CD root Application manifest not found in %s\n' "$DELIVERY_DIR/argocd" >&2
  exit 2
fi

CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  printf 'Refusing to bootstrap Argo CD: current kubectl context is "%s"; expected "%s".\n' \
    "$CURRENT_CONTEXT" "$EXPECTED_CONTEXT" >&2
  printf 'If this is an alternate kubectl context name for the same production cluster, set EXPECTED_CONTEXT to that name.\n' >&2
  exit 2
fi

if ! kubectl get nodes >/dev/null; then
  printf 'Cannot reach the EKS API. Establish the SSM tunnel and configure kubectl first.\n' >&2
  exit 2
fi

printf 'Bootstrapping Argo CD chart %s into context %s.\n' "$ARGOCD_CHART_VERSION" "$CURRENT_CONTEXT"

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --set server.service.type=ClusterIP \
  --wait \
  --timeout 10m

kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io \
  crd/appprojects.argoproj.io

# The delivery AppProject intentionally cannot create cluster-scoped namespaces.
kubectl create namespace "$APPLICATION_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$DELIVERY_DIR/argocd/root-app.yaml"

printf '\nArgo CD bootstrap is complete. Check GitOps reconciliation with:\n'
printf '  kubectl get applications -n argocd\n'
printf '  kubectl get pods -n argocd\n'
printf '  kubectl get pods,ingress -n %s\n' "$APPLICATION_NAMESPACE"
