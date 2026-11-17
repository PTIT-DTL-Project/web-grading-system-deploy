#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAULT_TEST_CONFIRM:-}" != "I_UNDERSTAND_THIS_BREAKS_STAGING" ]]; then
  echo "Refusing fault injection. Set FAULT_TEST_CONFIRM=I_UNDERSTAND_THIS_BREAKS_STAGING only after the staging checklist." >&2
  exit 2
fi
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT explicitly to the approved staging context}"
: "${KUBE_NAMESPACE:?Set KUBE_NAMESPACE explicitly (normally web-grading on staging)}"

context="$(kubectl config current-context)"
if [[ "$context" != "$KUBE_CONTEXT" ]]; then
  echo "Current kubectl context '$context' does not equal KUBE_CONTEXT '$KUBE_CONTEXT'; refusing." >&2
  exit 2
fi
if [[ "$context" =~ (^|[-_])(prod|production)([-_]|$) ]]; then
  echo "Production-like context detected; refusing fault injection." >&2
  exit 2
fi
if [[ "$KUBE_NAMESPACE" =~ (^|[-_])(prod|production)([-_]|$) ]]; then
  echo "Production-like namespace detected; refusing fault injection." >&2
  exit 2
fi

usage() {
  cat >&2 <<'EOF'
Usage: guarded-fault-test.sh delete-executor-pod | scale-result-service-zero | test-selfheal-replicas

This tool requires a second confirmation for each operation and does not run
ArgoCD rollback. Rollback must be performed through the approved Git PR flow.
EOF
  exit 2
}

[[ $# -eq 1 ]] || usage

confirm_operation() {
  local prompt="$1" expected
  read -r -p "$prompt Type '$KUBE_CONTEXT/$KUBE_NAMESPACE' to continue: " expected
  [[ "$expected" == "$KUBE_CONTEXT/$KUBE_NAMESPACE" ]] || {
    echo "Confirmation did not match; no changes made." >&2
    exit 2
  }
}

case "$1" in
  delete-executor-pod)
    deployment="grading-executor-service"
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deployment "$deployment" >/dev/null
    pod="$(kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get pods -l app=executor-service -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "$pod" ]] || { echo "No executor-service pod found." >&2; exit 1; }
    confirm_operation "This deletes executor pod '$pod' during a selected grading phase."
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" delete pod "$pod"
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" rollout status "deployment/$deployment" --timeout=5m
    ;;
  scale-result-service-zero)
    deployment="grading-result-service"
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deployment "$deployment" >/dev/null
    confirm_operation "This removes all result-service replicas and breaks result writes."
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" scale "deployment/$deployment" --replicas=0
    echo "Fault applied. Restore replicas immediately after the observation window:"
    echo "kubectl --context '$KUBE_CONTEXT' -n '$KUBE_NAMESPACE' scale deployment/grading-result-service --replicas=1"
    ;;
  test-selfheal-replicas)
    deployment="grading-executor-service"
    desired="$(kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
    [[ "$desired" == "2" ]] || { echo "Expected exactly 2 desired executor replicas for this staging test; found '$desired'." >&2; exit 1; }
    confirm_operation "This scales executor from 2 to 1 temporarily; one grading worker remains."
    kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" scale deployment "$deployment" --replicas=1
    echo "Waiting up to 5 minutes for ArgoCD selfHeal to restore the Git-managed replica count (2)."
    for _ in $(seq 1 60); do
      current="$(kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
      ready="$(kubectl --context "$KUBE_CONTEXT" -n "$KUBE_NAMESPACE" get deployment "$deployment" -o jsonpath='{.status.readyReplicas}')"
      if [[ "$current" == "2" && "$ready" == "2" ]]; then
        echo "SELF_HEAL=PASS (executor deployment restored to 2 ready replicas)."
        exit 0
      fi
      sleep 5
    done
    echo "SELF_HEAL=NOT_OBSERVED; inspect ArgoCD sync/selfHeal and restore desired state before leaving staging."
    exit 1
    ;;
  *) usage ;;
esac
