#!/usr/bin/env bash
#
# Delete the disposable Aurora walkthrough resources.
#
# SAMPLE CODE — NOT FOR PRODUCTION USE. This script tears down the throwaway
# environment used to demonstrate the concepts in the accompanying AWS Database
# Blog post. See README.md.
#
# DESTRUCTIVE. This skips final snapshots and permanently deletes the sample
# database. Use it only for throwaway test resources. To keep the data, delete
# the cluster manually with --final-db-snapshot-identifier instead.
#
# Run this from a session with RDS and EC2 administrative rights — normally the
# workstation that ran provision-aurora.sh. Do NOT run it from the benchmark
# client: that instance's role typically carries only SSM permissions, so
# rds:DeleteDBInstance fails with AccessDenied and the script aborts before
# deleting or terminating anything.
#
# Required environment variables:
#   AWS_REGION
#   DB_CLUSTER_IDENTIFIER
#   DB_INSTANCE_IDENTIFIER
#   DB_SECURITY_GROUP_ID
#   CLIENT_SECURITY_GROUP_ID
#
# Optional:
#   KEEP_INGRESS_RULE Set to "true" to leave the port 5432 ingress rule alone.
#                     Use this when the rule already existed before the
#                     walkthrough, so teardown does not remove someone else's
#                     access.
#   EC2_INSTANCE_ID   Terminate this instance. Only set it for an instance
#                     created exclusively for this walkthrough — never a shared
#                     application host.

set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

for var in AWS_REGION DB_CLUSTER_IDENTIFIER DB_INSTANCE_IDENTIFIER \
           DB_SECURITY_GROUP_ID CLIENT_SECURITY_GROUP_ID; do
  require "${var}"
done

cat <<EOF
This will permanently delete, with no final snapshot:
  Aurora writer  : ${DB_INSTANCE_IDENTIFIER}
  Aurora cluster : ${DB_CLUSTER_IDENTIFIER}
  Ingress rule   : port 5432 on ${DB_SECURITY_GROUP_ID} from ${CLIENT_SECURITY_GROUP_ID}
EOF
if [[ -n "${EC2_INSTANCE_ID:-}" ]]; then
  echo "  EC2 instance   : ${EC2_INSTANCE_ID}"
fi
echo
read -r -p "Type 'delete' to continue: " confirm
[[ "${confirm}" == "delete" ]] || { echo "Aborted."; exit 0; }

echo "==> Deleting the Aurora writer instance"
aws rds delete-db-instance \
  --region "${AWS_REGION}" \
  --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
  --skip-final-snapshot

aws rds wait db-instance-deleted \
  --region "${AWS_REGION}" \
  --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}"

echo "==> Deleting the Aurora cluster"
aws rds delete-db-cluster \
  --region "${AWS_REGION}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}" \
  --skip-final-snapshot

aws rds wait db-cluster-deleted \
  --region "${AWS_REGION}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}"

if [[ "${KEEP_INGRESS_RULE:-false}" == "true" ]]; then
  echo "==> Leaving the ingress rule in place (KEEP_INGRESS_RULE=true)"
else
  # A missing rule is not an error. Do not let this step abort the script: the
  # EC2 termination below is what stops the client instance billing.
  echo "==> Revoking the walkthrough ingress rule"
  if revoke_result=$(aws ec2 revoke-security-group-ingress \
        --region "${AWS_REGION}" \
        --group-id "${DB_SECURITY_GROUP_ID}" \
        --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${CLIENT_SECURITY_GROUP_ID}}]" 2>&1); then
    echo "    rule revoked"
  elif [[ "${revoke_result}" == *InvalidPermission.NotFound* ]]; then
    echo "    rule not present, continuing"
  else
    echo "${revoke_result}" >&2
    echo "    WARNING: could not revoke the ingress rule; continuing so that any" >&2
    echo "             EC2 client below is still terminated. Revoke it manually." >&2
  fi
fi

if [[ -n "${EC2_INSTANCE_ID:-}" ]]; then
  echo "==> Terminating ${EC2_INSTANCE_ID}"
  aws ec2 terminate-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${EC2_INSTANCE_ID}"
fi

echo "Done. Remember to delete any secret you created in AWS Secrets Manager."
