#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$(cd -- "$DELIVERY_DIR/../swordhealth-aws-eks-terraform-challenge" && pwd)}"
TF_DIR="$INFRA_DIR/terraform/environments"
AWS_PROFILE="${AWS_PROFILE:-terraform-lab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_CLI_PROBE_IMAGE="${AWS_CLI_PROBE_IMAGE:-amazon/aws-cli:2.27.41}"
CURL_PROBE_IMAGE="${CURL_PROBE_IMAGE:-curlimages/curl:8.12.1}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
PROBE_PODS=()

pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  printf 'WARN: %s\n' "$1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

cleanup() {
  local entry
  for entry in "${PROBE_PODS[@]}"; do
    local namespace="${entry%%:*}"
    local pod="${entry#*:}"
    kubectl delete pod "$pod" --namespace "$namespace" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 ||
      printf 'WARN: could not confirm cleanup of probe pod %s/%s\n' "$namespace" "$pod" >&2
  done
}
trap cleanup EXIT

for tool in aws kubectl terraform curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 2
  fi
done

if [[ ! -d "$TF_DIR" ]]; then
  printf 'Terraform environment directory not found: %s\nSet INFRA_DIR to the infrastructure repository path.\n' "$TF_DIR" >&2
  exit 2
fi

export AWS_PROFILE AWS_REGION

printf 'Challenge demo validation\nAWS profile: %s\nAWS region: %s\nTerraform root: %s\n\n' \
  "$AWS_PROFILE" "$AWS_REGION" "$TF_DIR"
printf 'This script is read-only except for three temporary probe pods, which are deleted on exit.\n\n'

if ! aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null; then
  printf 'AWS credentials are unavailable. Run aws sso login --profile %s and retry.\n' "$AWS_PROFILE" >&2
  exit 2
fi
pass "AWS credentials are available"

if ! TF_OUTPUTS="$(terraform -chdir="$TF_DIR" output -json)"; then
  printf 'Could not read Terraform outputs. Initialize the infrastructure backend and apply the environment first.\n' >&2
  exit 2
fi

tf_output() {
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]]["value"]))' "$1" <<<"$TF_OUTPUTS" |
    python3 -c 'import json,sys; v=json.load(sys.stdin); print(v if isinstance(v,str) else json.dumps(v))'
}

CLUSTER_NAME="$(tf_output cluster_name)"
APP_NAMESPACE="$(tf_output application_namespace)"
APP_SERVICE_ACCOUNT="$(tf_output application_service_account_name)"
APP_ROLE_ARN="$(tf_output application_role_arn)"
READ_BUCKET="$(tf_output application_read_only_bucket)"
WRITE_BUCKET="$(tf_output application_write_only_bucket)"
QUEUE_URL="$(tf_output application_queue_url)"
CONTROLLER_ROLE_ARN="$(tf_output load_balancer_controller_role_arn)"
PUBLIC_SUBNET_CIDRS="$(tf_output public_subnet_cidrs)"
QUEUE_ARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true)"

check_private_cluster() {
  local details
  details="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json)" || return 1
  python3 -c '
import json,sys
c=json.load(sys.stdin)["cluster"]
assert c["status"] == "ACTIVE", "cluster status is " + c["status"]
assert c["resourcesVpcConfig"]["endpointPrivateAccess"] is True, "private endpoint is disabled"
assert c["resourcesVpcConfig"]["endpointPublicAccess"] is False, "public endpoint is enabled"
' <<<"$details"
}
if check_private_cluster; then pass "EKS is active with private API access and no public endpoint"; else fail "EKS status or endpoint exposure is incorrect"; fi

if kubectl get nodes -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d["items"]; assert n and all(any(c["type"]=="Ready" and c["status"]=="True" for c in x["status"]["conditions"]) for x in n), "one or more nodes are not Ready"'; then
  pass "EKS worker nodes are Ready"
else
  fail "Could not verify Ready EKS worker nodes"
fi

check_argo_app() {
  local name="$1"
  kubectl get application "$name" --namespace argocd -o json |
    python3 -c '
import json,sys
s=json.load(sys.stdin).get("status",{})
sync=s.get("sync",{}).get("status")
health=s.get("health",{}).get("status")
assert sync=="Synced", "sync=" + str(sync)
assert health=="Healthy", "health=" + str(health)
'
}
if check_argo_app swordhealth-root; then pass "Argo CD root Application is Synced and Healthy"; else fail "Argo CD root Application is not healthy"; fi
if check_argo_app aws-load-balancer-controller-prod; then pass "AWS Load Balancer Controller Application is Synced and Healthy"; else fail "AWS Load Balancer Controller Application is not healthy"; fi
if check_argo_app node-example-prod; then pass "node-example Application is Synced and Healthy"; else fail "node-example Application is not healthy"; fi

if kubectl rollout status deployment/node-example --namespace "$APP_NAMESPACE" --timeout=90s >/dev/null; then
  pass "node-example deployment rollout is complete"
else
  fail "node-example deployment rollout did not complete"
fi

if kubectl get serviceaccount "$APP_SERVICE_ACCOUNT" --namespace "$APP_NAMESPACE" >/dev/null 2>&1; then
  pass "application service account exists in $APP_NAMESPACE"
else
  fail "application service account is missing"
fi

check_pod_identity_association() {
  local namespace="$1"
  local service_account="$2"
  local expected_role="$3"
  local associations association_id actual_role
  associations="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$namespace" \
    --service-account "$service_account" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --output json)" || return 1
  association_id="$(python3 -c '
import json,sys
items=json.load(sys.stdin).get("associations",[])
print(items[0]["associationId"] if items else "")
' <<<"$associations")"
  [[ -n "$association_id" ]] || return 1
  actual_role="$(aws eks describe-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --association-id "$association_id" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --query 'association.roleArn' \
    --output text)" || return 1
  [[ "$actual_role" == "$expected_role" ]]
}

if check_pod_identity_association "$APP_NAMESPACE" "$APP_SERVICE_ACCOUNT" "$APP_ROLE_ARN"; then
  pass "Terraform created the application EKS Pod Identity association"
else
  fail "application EKS Pod Identity association is missing or has the wrong role"
fi

if check_pod_identity_association kube-system aws-load-balancer-controller "$CONTROLLER_ROLE_ARN"; then
  pass "Terraform created the load balancer controller EKS Pod Identity association"
else
  fail "load balancer controller EKS Pod Identity association is missing or has the wrong role"
fi

if kubectl get networkpolicy node-example-ingress --namespace "$APP_NAMESPACE" -o json |
  python3 -c '
import json,sys
p=json.load(sys.stdin)["spec"]
assert "Ingress" in p["policyTypes"], "policy does not isolate ingress"
allowed={r["ipBlock"]["cidr"] for rule in p.get("ingress",[]) for r in rule.get("from",[]) if "ipBlock" in r}
expected=set(json.loads(sys.argv[1]))
assert allowed == expected, f"allowed CIDRs {allowed} do not match expected public subnet CIDRs {expected}"
' "$PUBLIC_SUBNET_CIDRS"; then
  pass "application ingress NetworkPolicy is installed and allows only configured CIDR rules"
else
  fail "application ingress NetworkPolicy is missing or malformed"
fi

INGRESS_HOST="$(kubectl get ingress node-example --namespace "$APP_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -z "$INGRESS_HOST" ]]; then
  fail "application Ingress has no ALB hostname"
else
  pass "application Ingress has ALB hostname $INGRESS_HOST"
  HTTP_CODE="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 20 "http://$INGRESS_HOST/" 2>/dev/null || true)"
  if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    pass "application responds through the ALB (HTTP $HTTP_CODE)"
  else
    fail "application did not return HTTP 2xx through the ALB (HTTP ${HTTP_CODE:-no response})"
  fi
fi

if TARGET_GROUP_ARN="$(kubectl get targetgroupbinding --namespace "$APP_NAMESPACE" -o jsonpath='{.items[0].spec.targetGroupARN}' 2>/dev/null)" &&
  [[ -n "$TARGET_GROUP_ARN" ]] &&
  aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json |
    python3 -c 'import json,sys; t=json.load(sys.stdin)["TargetHealthDescriptions"]; assert t and all(x["TargetHealth"]["State"]=="healthy" for x in t), [(x["Target"]["Id"],x["TargetHealth"]["State"]) for x in t]'; then
  pass "all ALB targets are healthy"
else
  fail "one or more ALB targets are unhealthy or unavailable"
fi

if kubectl auth can-i list pods --namespace kube-system --as="system:serviceaccount:$APP_NAMESPACE:$APP_SERVICE_ACCOUNT" | grep -qx yes &&
  ! kubectl auth can-i delete pods --namespace kube-system --as="system:serviceaccount:$APP_NAMESPACE:$APP_SERVICE_ACCOUNT" | grep -qx yes; then
  pass "application RBAC allows listing but denies deleting kube-system pods"
else
  fail "application kube-system RBAC is broader or narrower than expected"
fi

make_probe() {
  local namespace="$1"
  local name="$2"
  local image="$3"
  shift 3
  PROBE_PODS+=("$namespace:$name")
  kubectl run "$name" --namespace "$namespace" --image "$image" --restart=Never "$@" >/dev/null
  kubectl wait --for=condition=Ready "pod/$name" --namespace "$namespace" --timeout=180s >/dev/null
}

IAM_PROBE="demo-iam-probe-$$"
if make_probe "$APP_NAMESPACE" "$IAM_PROBE" "$AWS_CLI_PROBE_IMAGE" \
  --env="AWS_REGION=$AWS_REGION" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"$APP_SERVICE_ACCOUNT\"}}" \
  --command -- /bin/sh -c 'sleep 1800'; then
  if IDENTITY="$(kubectl exec "$IAM_PROBE" --namespace "$APP_NAMESPACE" -- aws sts get-caller-identity --output json 2>/dev/null)" &&
    python3 -c '
import json,sys
identity=json.load(sys.stdin)
expected=sys.argv[1].split(":role/")[-1]
assert f":assumed-role/{expected}/" in identity["Arn"], "unexpected role: " + identity["Arn"]
' "$APP_ROLE_ARN" <<<"$IDENTITY"; then
    pass "application service account receives its expected EKS Pod Identity role"
  else
    fail "application service account could not assume its expected AWS role"
  fi

  if kubectl exec "$IAM_PROBE" --namespace "$APP_NAMESPACE" -- aws s3api list-objects-v2 \
    --bucket "$READ_BUCKET" --max-keys 1 --region "$AWS_REGION" >/dev/null 2>&1; then
    pass "application Pod Identity can list the read-only S3 bucket"
  else
    fail "application Pod Identity cannot list the read-only S3 bucket"
  fi

  if [[ -n "$QUEUE_ARN" ]] && kubectl exec "$IAM_PROBE" --namespace "$APP_NAMESPACE" -- aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" --attribute-names QueueArn --region "$AWS_REGION" >/dev/null 2>&1; then
    pass "application Pod Identity can read its SQS queue attributes"
  else
    fail "application Pod Identity cannot read its SQS queue attributes"
  fi
else
  fail "could not start temporary AWS CLI pod using the application service account"
fi

simulate_iam() {
  local action="$1"
  local resource="$2"
  local expected="$3"
  local decision
  decision="$(aws iam simulate-principal-policy \
    --policy-source-arn "$APP_ROLE_ARN" \
    --action-names "$action" \
    --resource-arns "$resource" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE")" || return 1
  [[ "$decision" == "$expected" ]]
}

READ_BUCKET_ARN="arn:aws:s3:::$READ_BUCKET"
WRITE_BUCKET_ARN="arn:aws:s3:::$WRITE_BUCKET"

if [[ -n "$QUEUE_ARN" ]] &&
  simulate_iam s3:ListBucket "$READ_BUCKET_ARN" allowed &&
  simulate_iam s3:GetObject "$READ_BUCKET_ARN/*" allowed &&
  simulate_iam s3:PutObject "$WRITE_BUCKET_ARN/*" allowed &&
  simulate_iam s3:PutObject "$READ_BUCKET_ARN/*" implicitDeny &&
  simulate_iam s3:GetObject "$WRITE_BUCKET_ARN/*" implicitDeny &&
  simulate_iam sqs:ReceiveMessage "$QUEUE_ARN" allowed; then
  pass "IAM policy simulation confirms read/write bucket separation and SQS consume access"
else
  warn "IAM simulator did not confirm every expected action; check simulator permissions and Terraform role policy"
fi

if [[ -n "$QUEUE_ARN" ]]; then
  pass "application SQS queue exists"
else
  fail "application SQS queue could not be read"
fi

APP_API_PROBE="demo-kube-api-probe-$$"
if make_probe "$APP_NAMESPACE" "$APP_API_PROBE" "$CURL_PROBE_IMAGE" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"$APP_SERVICE_ACCOUNT\"}}" \
  --command -- sleep 1800; then
  if POD_LIST="$(kubectl exec "$APP_API_PROBE" --namespace "$APP_NAMESPACE" -- sh -c \
    'TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"; curl --fail --silent --show-error --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces/kube-system/pods' 2>/dev/null)" &&
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("items"),list), "API did not return a pod list"' <<<"$POD_LIST"; then
    pass "application service account can list kube-system pods through the Kubernetes API"
  else
    fail "application service account could not list kube-system pods through the Kubernetes API"
  fi
else
  fail "could not start temporary Kubernetes API probe pod"
fi

NETPOL_PROBE="demo-netpol-probe-$$"
if make_probe default "$NETPOL_PROBE" "$CURL_PROBE_IMAGE" --command -- sleep 1800; then
  if kubectl exec "$NETPOL_PROBE" --namespace default -- nslookup "node-example.$APP_NAMESPACE.svc.cluster.local" >/dev/null 2>&1; then
    if kubectl get endpointslice -n "$APP_NAMESPACE" -l kubernetes.io/service-name=node-example -o json |
      python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(e.get("endpoints") for e in d["items"]), "service has no endpoints"'; then
      if kubectl exec "$NETPOL_PROBE" --namespace default -- curl --silent --show-error --connect-timeout 5 --max-time 10 \
        "http://node-example.$APP_NAMESPACE.svc.cluster.local/" >/dev/null 2>&1; then
        fail "a pod in another namespace reached the application Service; network isolation failed"
      else
        pass "pod-originated traffic from another namespace is blocked from the application"
      fi
    else
      fail "application Service has no ready endpoints; cannot verify pod isolation"
    fi
  else
    fail "temporary probe could not resolve the application Service; cannot verify pod isolation"
  fi
else
  fail "could not start temporary network-policy probe pod"
fi

for bucket in "$READ_BUCKET" "$WRITE_BUCKET"; do
  if aws s3api get-public-access-block --bucket "$bucket" --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json |
    python3 -c 'import json,sys; c=json.load(sys.stdin)["PublicAccessBlockConfiguration"]; assert all(c[k] for k in ("BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets"))'; then
    pass "S3 bucket $bucket blocks public access"
  else
    fail "S3 bucket $bucket does not have all Block Public Access settings enabled"
  fi

  if aws s3api get-bucket-versioning --bucket "$bucket" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query Status --output text | grep -qx Enabled; then
    pass "S3 bucket $bucket has versioning enabled"
  else
    fail "S3 bucket $bucket does not have versioning enabled"
  fi

  if aws s3api get-bucket-encryption --bucket "$bucket" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text | grep -qx AES256; then
    pass "S3 bucket $bucket has default encryption"
  else
    fail "S3 bucket $bucket default encryption is not AES256"
  fi
done

if aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names SqsManagedSseEnabled --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'Attributes.SqsManagedSseEnabled' --output text | grep -qx true; then
  pass "SQS queue has server-side encryption enabled"
else
  fail "SQS queue server-side encryption is not enabled"
fi

DB_ENDPOINT="$(tf_output database_endpoint)"
if DB_DETAILS="$(aws rds describe-db-instances --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json 2>/dev/null)" &&
  python3 -c '
import json,sys
instances=json.load(sys.stdin)["DBInstances"]
db=next((x for x in instances if x.get("Endpoint",{}).get("Address")==sys.argv[1]),None)
assert db is not None, "database instance not found"
assert db["DBInstanceStatus"]=="available", "database status is " + db["DBInstanceStatus"]
assert db["PubliclyAccessible"] is False, "database is publicly accessible"
assert db["BackupRetentionPeriod"] >= 7, "backup retention is less than seven days"
print("RDS Multi-AZ: {}; backup retention: {} days".format(db["MultiAZ"], db["BackupRetentionPeriod"]))
' "$DB_ENDPOINT" <<<"$DB_DETAILS"; then
  pass "MySQL is available, private, and configured with at least seven-day backup retention"
else
  fail "MySQL availability, exposure, or backup retention does not meet the demo requirements"
fi

if aws backup list-restore-testing-plans --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json |
  python3 -c '
import json,sys
plans=json.load(sys.stdin).get("RestoreTestingPlans",[])
assert any(p.get("RestoreTestingPlanName")=="swordhealth_prod_mysql_weekly" for p in plans), "weekly MySQL restore test is not configured"
'; then
  pass "weekly AWS Backup MySQL restore-testing plan is configured"
else
  fail "weekly AWS Backup MySQL restore-testing plan is missing"
fi

if aws backup list-recovery-points-by-backup-vault --backup-vault-name swordhealth-prod-mysql --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json |
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("RecoveryPoints") else 1)'; then
  pass "AWS Backup vault has at least one recovery point"
else
  warn "No AWS Backup recovery point was found yet; wait for the scheduled backup and verify a restore test separately"
fi

printf '\nResults: %d passed, %d failed, %d warnings\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
