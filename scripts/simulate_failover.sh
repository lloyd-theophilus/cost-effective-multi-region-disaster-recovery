#!/usr/bin/env bash
# simulate_failover.sh
# Game-day DR failover simulation script.
# Injects failures into the primary region and verifies automated failover.
#
# Usage:
#   ./simulate_failover.sh --dry-run        # describe what would happen, no changes
#   ./simulate_failover.sh --execute        # trigger real failover test
#   ./simulate_failover.sh --restore        # restore primary after test

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-myapp}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-eu-west-1}"
DOMAIN="${DOMAIN:-api.example.com}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/health}"
PRIMARY_ALB_LISTENER_ARN="${PRIMARY_ALB_LISTENER_ARN:-}"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# ── Argument Parsing ──────────────────────────────────────────────
MODE=""
for arg in "$@"; do
  case $arg in
    --dry-run)  MODE="dry-run"  ;;
    --execute)  MODE="execute"  ;;
    --restore)  MODE="restore"  ;;
    *)          echo "Usage: $0 --dry-run | --execute | --restore"; exit 1 ;;
  esac
done

[[ -z "$MODE" ]] && { echo "Specify --dry-run, --execute, or --restore"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}\n"; }

run() {
  if [[ "$MODE" == "dry-run" ]]; then
    echo -e "  ${YELLOW}[DRY RUN]${NC} Would run: $*"
  else
    eval "$@"
  fi
}

check_prereqs() {
  section "Checking Prerequisites"
  for cmd in aws curl jq dig; do
    if command -v "$cmd" &>/dev/null; then
      success "$cmd found"
    else
      error "$cmd not found — install it before running this script"
      exit 1
    fi
  done

  aws sts get-caller-identity --region "$PRIMARY_REGION" &>/dev/null \
    && success "AWS credentials valid" \
    || { error "AWS credentials not configured"; exit 1; }
}

capture_baseline() {
  section "Capturing Baseline Metrics"

  log "Primary region DNS resolution:"
  dig +short "$DOMAIN" || warn "DNS lookup failed"

  log "Primary health check:"
  curl -sf --max-time 5 "https://${DOMAIN}${HEALTH_CHECK_PATH}" \
    && success "Primary health check OK" \
    || warn "Primary health check failed (expected if already failed over)"

  log "Current Route 53 health check status:"
  HEALTH_CHECK_ID=$(aws route53 list-health-checks \
    --query "HealthChecks[?contains(HealthCheckConfig.FullyQualifiedDomainName, '${DOMAIN}')].Id" \
    --output text 2>/dev/null | head -1)

  if [[ -n "$HEALTH_CHECK_ID" ]]; then
    aws route53 get-health-check-status \
      --health-check-id "$HEALTH_CHECK_ID" \
      --query 'HealthCheckObservations[*].{Region:Region,StatusReport:StatusReport.Status}' \
      --output table 2>/dev/null || warn "Could not fetch health check status"
  fi

  log "ECS service status (primary):"
  aws ecs describe-services \
    --region "$PRIMARY_REGION" \
    --cluster "${APP_NAME}-primary" \
    --services "${APP_NAME}-primary-service" \
    --query 'services[0].{Running:runningCount,Desired:desiredCount,Status:status}' \
    --output table 2>/dev/null || warn "Could not fetch ECS status"

  log "Aurora replication lag (DR cluster):"
  aws cloudwatch get-metric-statistics \
    --region "$DR_REGION" \
    --namespace AWS/RDS \
    --metric-name AuroraGlobalDBReplicationLag \
    --dimensions Name=DBClusterIdentifier,Value="${APP_NAME}-dr-aurora" \
    --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%S')" \
    --end-time "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
    --period 60 --statistics Maximum \
    --query 'Datapoints[-1].Maximum' \
    --output text 2>/dev/null | xargs -I{} echo "Replication lag: {}ms" || warn "Could not fetch replication lag"
}

inject_failure() {
  section "Injecting Failure — Primary ALB Returns 503"
  warn "This will cause Route 53 health checks to fail and trigger automated failover."
  warn "Press Ctrl+C within 10 seconds to abort."
  sleep 10

  if [[ -z "$PRIMARY_ALB_LISTENER_ARN" ]]; then
    error "PRIMARY_ALB_LISTENER_ARN not set. Export it and re-run."
    echo "  export PRIMARY_ALB_LISTENER_ARN=\$(aws elbv2 describe-listeners --region $PRIMARY_REGION --load-balancer-arn \$(aws elbv2 describe-load-balancers --region $PRIMARY_REGION --names ${APP_NAME}-primary-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text) --query 'Listeners[?Port==\`443\`].ListenerArn' --output text)"
    exit 1
  fi

  # Store original rule ARN for restore
  ORIGINAL_RULE_ARN=$(aws elbv2 describe-rules \
    --region "$PRIMARY_REGION" \
    --listener-arn "$PRIMARY_ALB_LISTENER_ARN" \
    --query 'Rules[?IsDefault==`true`].RuleArn' \
    --output text)

  log "Modifying default listener rule to return 503..."
  run aws elbv2 modify-rule \
    --region "$PRIMARY_REGION" \
    --rule-arn "$ORIGINAL_RULE_ARN" \
    --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=503,ContentType=text/plain,MessageBody=FAILOVER_TEST}'

  success "Primary ALB now returning 503 — failover should trigger automatically"
  echo "$ORIGINAL_RULE_ARN" > /tmp/dr_test_rule_arn.txt
}

monitor_failover() {
  section "Monitoring Failover Progress"
  log "Polling DNS and DR ECS service every 15 seconds for 20 minutes..."

  START_TIME=$SECONDS
  MAX_WAIT=1200

  while (( SECONDS - START_TIME < MAX_WAIT )); do
    ELAPSED=$(( SECONDS - START_TIME ))
    RESOLVED_IP=$(dig +short "$DOMAIN" | head -1)

    ECS_RUNNING=$(aws ecs describe-services \
      --region "$DR_REGION" \
      --cluster "${APP_NAME}-dr" \
      --services "${APP_NAME}-dr-service" \
      --query 'services[0].runningCount' \
      --output text 2>/dev/null || echo "0")

    HEALTH_RESP=$(curl -sf --max-time 5 "https://${DOMAIN}${HEALTH_CHECK_PATH}" \
      && echo "HEALTHY" || echo "UNHEALTHY")

    printf "[%4ds] DNS: %-16s | DR ECS running: %-3s | Health: %s\n" \
      "$ELAPSED" "$RESOLVED_IP" "$ECS_RUNNING" "$HEALTH_RESP"

    if [[ "$HEALTH_RESP" == "HEALTHY" ]] && (( ECS_RUNNING >= 2 )); then
      echo ""
      success "Failover complete! Application healthy in DR region."
      success "Total failover time: ${ELAPSED}s"
      break
    fi

    sleep 15
  done

  if (( SECONDS - START_TIME >= MAX_WAIT )); then
    error "Failover did not complete within 20 minutes — manual investigation required"
    exit 1
  fi
}

restore_primary() {
  section "Restoring Primary Region"
  warn "This restores the ALB listener rule to forward traffic normally."

  if [[ ! -f /tmp/dr_test_rule_arn.txt ]]; then
    error "Rule ARN file not found at /tmp/dr_test_rule_arn.txt — cannot auto-restore"
    echo "Manually update the ALB default listener rule to forward to your target group."
    exit 1
  fi

  RULE_ARN=$(cat /tmp/dr_test_rule_arn.txt)
  TG_ARN=$(aws elbv2 describe-target-groups \
    --region "$PRIMARY_REGION" \
    --names "${APP_NAME}-primary-tg" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

  log "Restoring default listener rule to forward to target group..."
  run aws elbv2 modify-rule \
    --region "$PRIMARY_REGION" \
    --rule-arn "$RULE_ARN" \
    --actions "Type=forward,TargetGroupArn=${TG_ARN}"

  success "Primary ALB restored to normal forwarding"
  warn "NOTE: You must also manually re-add the DR Aurora cluster back to the global cluster"
  warn "and update Route 53 records once you are satisfied with the post-failover state."
  rm -f /tmp/dr_test_rule_arn.txt
}

write_report() {
  section "Game Day Report"
  REPORT_FILE="/tmp/${APP_NAME}_dr_game_day_$(date '+%Y%m%d_%H%M%S').txt"
  {
    echo "DR Game Day Report — ${APP_NAME}"
    echo "Date: $(date)"
    echo "Mode: $MODE"
    echo "Primary Region: $PRIMARY_REGION"
    echo "DR Region: $DR_REGION"
    echo ""
    echo "Results captured above. Attach this file to your DR runbook update."
  } > "$REPORT_FILE"
  log "Report written to $REPORT_FILE"
}

# ── Main ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}${BLUE}AWS Multi-Region DR Failover Simulation${NC}"
echo -e "${BLUE}App: ${APP_NAME} | Primary: ${PRIMARY_REGION} | DR: ${DR_REGION}${NC}\n"

check_prereqs
capture_baseline

case "$MODE" in
  dry-run)
    section "DRY RUN — No changes will be made"
    inject_failure
    success "Dry run complete. Review the commands above and run with --execute when ready."
    ;;
  execute)
    inject_failure
    monitor_failover
    write_report
    ;;
  restore)
    restore_primary
    ;;
esac
