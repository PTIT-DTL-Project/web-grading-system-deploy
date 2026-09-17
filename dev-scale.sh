#!/usr/bin/env bash
# Scale one grading service down/up for local development.
# ArgoCD runs automated prune+selfHeal, so a plain `kubectl scale` would be
# reverted within minutes. This script suspends the app's automated sync
# before scaling to 0, and restores it when scaling back to 1.
#
# Usage:
#   bash dev-scale.sh                    # interactive menu
#   bash dev-scale.sh <service> <on|off|status>
#   bash dev-scale.sh status             # table of all services
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICES_ENV="$SCRIPT_DIR/deploy/argocd-apps/services.env"
STATE_DIR="$SCRIPT_DIR/.dev-scale-state"
NAMESPACE="web-grading"
ARGOCD_NS="argocd"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

die() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }
info() { echo -e "${YELLOW}➜ $*${NC}"; }
ok() { echo -e "${GREEN}✓ $*${NC}"; }

check_cluster() {
    kubectl cluster-info &>/dev/null || die "cannot reach cluster (is k3s running? bash start.sh)"
    kubectl get namespace "$NAMESPACE" &>/dev/null || die "namespace $NAMESPACE not found"
}

# Canonical service list, e.g. "executor-service"
list_services() {
    grep -v '^\s*#' "$SERVICES_ENV" | grep -v '^\s*$' | sed 's/[[:space:]]//g'
}

# Accept "executor" or "executor-service"
normalize_service() {
    local input="$1" svc
    for svc in $(list_services); do
        if [[ "$svc" == "$input" || "$svc" == "$input-service" ]]; then
            echo "$svc"
            return 0
        fi
    done
    return 1
}

app_name() { echo "grading-$1"; }        # ArgoCD Application
deploy_name() { echo "grading-$1"; }     # k3s Deployment (helm fullname == release)

check_service_exists() {
    local svc="$1"
    kubectl get deployment "$(deploy_name "$svc")" -n "$NAMESPACE" &>/dev/null \
        || die "deployment $(deploy_name "$svc") not found in $NAMESPACE"
    kubectl get application "$(app_name "$svc")" -n "$ARGOCD_NS" &>/dev/null \
        || die "ArgoCD application $(app_name "$svc") not found"
}

current_replicas() {
    kubectl get deployment "$(deploy_name "$1")" -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?"
}

automated_sync() {
    local out
    out=$(kubectl get application "$(app_name "$1")" -n "$ARGOCD_NS" \
        -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null) || { echo "?"; return; }
    if [[ -z "$out" || "$out" == "null" ]]; then
        echo "suspended"
    else
        echo "on"
    fi
}

do_off() {
    local svc="$1" app deploy state_file automated
    app="$(app_name "$svc")"
    deploy="$(deploy_name "$svc")"
    check_service_exists "$svc"

    if [[ "$(current_replicas "$svc")" == "0" ]]; then
        echo -e "${YELLOW}$svc is already scaled to 0 (sync: $(automated_sync "$svc"))${NC}"
        return 0
    fi

    info "Suspending ArgoCD automated sync for $app..."
    mkdir -p "$STATE_DIR"
    state_file="$STATE_DIR/$svc.json"
    automated=$(kubectl get application "$app" -n "$ARGOCD_NS" \
        -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null) || automated=""
    if [[ -n "$automated" && "$automated" != "null" ]]; then
        echo "$automated" > "$state_file"
    fi
    kubectl patch application "$app" -n "$ARGOCD_NS" --type=json \
        -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' &>/dev/null \
        || die "failed to suspend ArgoCD sync for $app"
    ok "ArgoCD sync suspended for $app"

    info "Scaling $deploy to 0..."
    kubectl scale "deployment/$deploy" -n "$NAMESPACE" --replicas=0
    kubectl wait --for=delete "pods" -l "app=$deploy" -n "$NAMESPACE" --timeout=120s &>/dev/null || true
    ok "$svc is OFF (replicas=0, ArgoCD sync suspended)"
    echo ""
    echo -e "${YELLOW}💡 Code $svc locally now. When done: bash dev-scale.sh $svc on${NC}"
}

do_on() {
    local svc="$1" app deploy state_file automated
    app="$(app_name "$svc")"
    deploy="$(deploy_name "$svc")"
    check_service_exists "$svc"

    info "Scaling $deploy to 1..."
    kubectl scale "deployment/$deploy" -n "$NAMESPACE" --replicas=1

    info "Restoring ArgoCD automated sync for $app..."
    state_file="$STATE_DIR/$svc.json"
    if [[ -f "$state_file" ]]; then
        automated=$(cat "$state_file")
    else
        automated='{"prune":true,"selfHeal":true}'
    fi
    kubectl patch application "$app" -n "$ARGOCD_NS" --type=merge \
        -p="{\"spec\":{\"syncPolicy\":{\"automated\":$automated}}}" &>/dev/null \
        || die "failed to restore ArgoCD sync for $app"
    rm -f "$state_file"
    ok "ArgoCD sync restored for $app"

    info "Waiting for rollout..."
    kubectl rollout status "deployment/$deploy" -n "$NAMESPACE" --timeout=180s
    ok "$svc is ON (replicas=1, ArgoCD sync restored)"
}

do_status_one() {
    local svc="$1"
    printf "  %-20s replicas=%-3s argocd-sync=%s\n" \
        "$svc" "$(current_replicas "$svc")" "$(automated_sync "$svc")"
}

do_status_all() {
    echo -e "${BLUE}Services in $NAMESPACE:${NC}"
    local svc
    for svc in $(list_services); do
        do_status_one "$svc"
    done
}

interactive() {
    check_cluster
    echo "Select service:"
    local services=() i=1 svc
    while IFS= read -r svc; do
        services+=("$svc")
        echo "  $i) $svc  [replicas=$(current_replicas "$svc"), sync=$(automated_sync "$svc")]"
        i=$((i + 1))
    done < <(list_services)
    read -r -p "Number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#services[@]} )) \
        || die "invalid choice"
    svc="${services[$((choice - 1))]}"
    echo "Select action for $svc:"
    echo "  1) off (code locally)"
    echo "  2) on (back to dev)"
    echo "  3) status"
    read -r -p "Number: " action
    case "$action" in
        1) do_off "$svc" ;;
        2) do_on "$svc" ;;
        3) do_status_one "$svc" ;;
        *) die "invalid choice" ;;
    esac
}

usage() {
    echo "Usage:"
    echo "  bash dev-scale.sh                        # interactive menu"
    echo "  bash dev-scale.sh <service> <on|off|status>"
    echo "  bash dev-scale.sh status                 # all services"
    echo ""
    echo "Services: $(list_services | tr '\n' ' ')"
}

main() {
    if [[ $# -eq 0 ]]; then
        interactive
        return
    fi
    if [[ "$1" == "status" && $# -eq 1 ]]; then
        check_cluster
        do_status_all
        return
    fi
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        return
    fi
    [[ $# -eq 2 ]] || { usage; exit 1; }
    case "$2" in
        off|on|status) ;;
        *) die "unknown action: $2 (use on|off|status)" ;;
    esac
    svc="$(normalize_service "$1" || die "unknown service: $1")"
    check_cluster
    case "$2" in
        off) do_off "$svc" ;;
        on) do_on "$svc" ;;
        status) do_status_one "$svc" ;;
    esac
}

main "$@"
