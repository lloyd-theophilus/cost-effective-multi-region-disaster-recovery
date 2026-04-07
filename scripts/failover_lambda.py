"""
failover_lambda.py
Automated DR failover orchestrator.
Triggered by SNS → CloudWatch Alarm when primary region health checks fail.

Sequence:
  1. Validate this is not a false-positive (idempotency check)
  2. Promote Aurora Global DB secondary cluster to standalone writer
  3. Update SSM parameters to point app at DR DB endpoint
  4. Scale ECS service to production desired count
  5. Publish completion event to SNS
  6. Return summary for CloudWatch Logs
"""

import boto3
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── Environment Variables (set by Terraform) ──────────────────────
GLOBAL_CLUSTER_ID  = os.environ["GLOBAL_CLUSTER_ID"]
DR_CLUSTER_ARN     = os.environ["DR_CLUSTER_ARN"]
DR_CLUSTER_ID      = os.environ["DR_CLUSTER_ID"]
ECS_CLUSTER        = os.environ["ECS_CLUSTER"]
ECS_SERVICE        = os.environ["ECS_SERVICE"]
PROD_TASK_COUNT    = int(os.environ["PROD_TASK_COUNT"])
APP_NAME           = os.environ["APP_NAME"]
DR_REGION          = os.environ["DR_REGION"]
NOTIFICATION_TOPIC = os.environ["NOTIFICATION_TOPIC"]

# ── AWS Clients ───────────────────────────────────────────────────
rds = boto3.client("rds",              region_name=DR_REGION)
ecs = boto3.client("ecs",              region_name=DR_REGION)
ssm = boto3.client("ssm",              region_name=DR_REGION)
sns = boto3.client("sns",              region_name=DR_REGION)
aas = boto3.client("application-autoscaling", region_name=DR_REGION)


# ── Helpers ───────────────────────────────────────────────────────
def log_step(step: int, message: str) -> None:
    logger.info(f"[FAILOVER STEP {step}] {message}")


def publish_notification(subject: str, message: dict) -> None:
    """Publish status to SNS for PagerDuty / Slack / email."""
    try:
        sns.publish(
            TopicArn=NOTIFICATION_TOPIC,
            Subject=subject,
            Message=json.dumps(message, indent=2, default=str),
        )
    except Exception as e:
        logger.error(f"Failed to publish SNS notification: {e}")


def is_already_writer() -> bool:
    """Check if the DR cluster is already a standalone writer (idempotency)."""
    resp = rds.describe_db_clusters(DBClusterIdentifier=DR_CLUSTER_ID)
    cluster = resp["DBClusters"][0]
    # If not part of a global cluster, it has already been promoted
    return cluster.get("GlobalWriteForwardingStatus") is None and \
           cluster.get("ReplicationSourceIdentifier") is None


def get_dr_cluster_endpoint() -> str:
    """Fetch the writer endpoint of the DR Aurora cluster."""
    resp = rds.describe_db_clusters(DBClusterIdentifier=DR_CLUSTER_ID)
    return resp["DBClusters"][0]["Endpoint"]


def get_dr_cluster_reader_endpoint() -> str:
    resp = rds.describe_db_clusters(DBClusterIdentifier=DR_CLUSTER_ID)
    return resp["DBClusters"][0]["ReaderEndpoint"]


# ── Step Functions ────────────────────────────────────────────────
def step_promote_aurora(dry_run: bool) -> str:
    """
    Promote the DR Aurora cluster from global replica to standalone writer.
    AllowDataLoss=False ensures we wait for full sync before promoting.
    Returns the new writer endpoint.
    """
    log_step(1, f"Initiating Aurora Global Cluster failover → {DR_CLUSTER_ARN}")

    if is_already_writer():
        log_step(1, "DR cluster already standalone writer — skipping Aurora failover")
        return get_dr_cluster_endpoint()

    if dry_run:
        log_step(1, "[DRY RUN] Would call rds.failover_global_cluster()")
        return "dry-run-endpoint.cluster-xxxxxxxx.eu-west-1.rds.amazonaws.com"

    rds.failover_global_cluster(
        GlobalClusterIdentifier=GLOBAL_CLUSTER_ID,
        TargetDbClusterIdentifier=DR_CLUSTER_ARN,
        AllowDataLoss=False,
    )

    # Poll until the cluster becomes the writer
    log_step(1, "Waiting for Aurora cluster promotion to complete...")
    max_wait_seconds = 600
    poll_interval    = 20
    elapsed          = 0

    while elapsed < max_wait_seconds:
        time.sleep(poll_interval)
        elapsed += poll_interval

        resp    = rds.describe_global_clusters(GlobalClusterIdentifier=GLOBAL_CLUSTER_ID)
        members = resp["GlobalClusters"][0].get("GlobalClusterMembers", [])

        for member in members:
            if member["DBClusterArn"] == DR_CLUSTER_ARN and member["IsWriter"]:
                endpoint = get_dr_cluster_endpoint()
                log_step(1, f"Aurora promotion complete. New writer endpoint: {endpoint}")
                return endpoint

        log_step(1, f"Still waiting for promotion... ({elapsed}s elapsed)")

    raise TimeoutError(
        f"Aurora failover did not complete within {max_wait_seconds}s. "
        "Check RDS console and complete manually."
    )


def step_update_ssm_parameters(db_endpoint: str, db_reader_endpoint: str, dry_run: bool) -> None:
    """Update SSM parameters so running ECS tasks pick up the new DB host on restart."""
    log_step(2, f"Updating SSM parameters with new DB endpoint: {db_endpoint}")

    params = {
        f"/{APP_NAME}/dr/db/endpoint":         db_endpoint,
        f"/{APP_NAME}/dr/db/reader_endpoint":  db_reader_endpoint,
        f"/{APP_NAME}/dr/failover/timestamp":  datetime.now(timezone.utc).isoformat(),
        f"/{APP_NAME}/dr/failover/status":     "active",
    }

    for name, value in params.items():
        if dry_run:
            log_step(2, f"[DRY RUN] Would set SSM {name} = {value}")
        else:
            ssm.put_parameter(
                Name=name,
                Value=value,
                Type="String",
                Overwrite=True,
            )
            log_step(2, f"SSM updated: {name}")


def step_scale_ecs(dry_run: bool) -> int:
    """Scale ECS service to production task count."""
    log_step(3, f"Scaling ECS service {ECS_SERVICE} to {PROD_TASK_COUNT} tasks")

    if dry_run:
        log_step(3, f"[DRY RUN] Would set desiredCount={PROD_TASK_COUNT}")
        return PROD_TASK_COUNT

    # Update the auto-scaling minimum so it won't scale back down
    aas.register_scalable_target(
        ServiceNamespace="ecs",
        ResourceId=f"service/{ECS_CLUSTER}/{ECS_SERVICE}",
        ScalableDimension="ecs:service:DesiredCount",
        MinCapacity=max(2, PROD_TASK_COUNT // 2),
        MaxCapacity=PROD_TASK_COUNT * 3,
    )

    # Set desired count directly
    ecs.update_service(
        cluster=ECS_CLUSTER,
        service=ECS_SERVICE,
        desiredCount=PROD_TASK_COUNT,
    )

    # Wait for tasks to reach steady state
    log_step(3, "Waiting for ECS service to reach steady state...")
    waiter = ecs.get_waiter("services_stable")
    waiter.wait(
        cluster=ECS_CLUSTER,
        services=[ECS_SERVICE],
        WaiterConfig={"Delay": 15, "MaxAttempts": 40},  # 10 minutes
    )

    resp    = ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE])
    running = resp["services"][0]["runningCount"]
    log_step(3, f"ECS steady state reached. Running tasks: {running}")
    return running


# ── Main Handler ──────────────────────────────────────────────────
def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Lambda entry point.
    Triggered by SNS. Parses the SNS message and executes failover steps.
    """
    started_at = datetime.now(timezone.utc)
    dry_run    = os.environ.get("DRY_RUN", "false").lower() == "true"

    logger.info(f"Failover orchestrator invoked. DRY_RUN={dry_run}")
    logger.info(f"Event: {json.dumps(event, default=str)}")

    publish_notification(
        subject=f"[{APP_NAME}] DR Failover INITIATED",
        message={
            "app":       APP_NAME,
            "status":    "initiated",
            "dry_run":   dry_run,
            "timestamp": started_at.isoformat(),
            "region":    DR_REGION,
        },
    )

    result: dict[str, Any] = {
        "app":           APP_NAME,
        "dry_run":       dry_run,
        "started_at":    started_at.isoformat(),
        "steps":         {},
    }

    try:
        # ── Step 1: Promote Aurora ────────────────────────────────
        db_endpoint        = step_promote_aurora(dry_run)
        db_reader_endpoint = get_dr_cluster_reader_endpoint() if not dry_run else db_endpoint
        result["steps"]["aurora_promotion"] = {
            "status":   "success",
            "endpoint": db_endpoint,
        }

        # ── Step 2: Update SSM ────────────────────────────────────
        step_update_ssm_parameters(db_endpoint, db_reader_endpoint, dry_run)
        result["steps"]["ssm_update"] = {"status": "success"}

        # ── Step 3: Scale ECS ─────────────────────────────────────
        running_count = step_scale_ecs(dry_run)
        result["steps"]["ecs_scale"] = {
            "status":        "success",
            "running_tasks": running_count,
        }

        # ── Summary ───────────────────────────────────────────────
        completed_at               = datetime.now(timezone.utc)
        elapsed                    = (completed_at - started_at).total_seconds()
        result["completed_at"]     = completed_at.isoformat()
        result["elapsed_seconds"]  = elapsed
        result["status"]           = "success"

        log_step(0, f"Failover completed successfully in {elapsed:.0f}s")

        publish_notification(
            subject=f"[{APP_NAME}] DR Failover COMPLETED ✓ ({elapsed:.0f}s)",
            message=result,
        )

    except Exception as e:
        result["status"] = "failed"
        result["error"]  = str(e)
        logger.error(f"Failover FAILED: {e}", exc_info=True)

        publish_notification(
            subject=f"[{APP_NAME}] DR Failover FAILED — MANUAL INTERVENTION REQUIRED",
            message=result,
        )
        raise

    return {"statusCode": 200, "body": json.dumps(result, default=str)}
