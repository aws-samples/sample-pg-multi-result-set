#!/usr/bin/env bash
#
# Provision a disposable Aurora PostgreSQL cluster and an EC2 client for the
# walkthrough. Every AWS-specific value comes from an environment variable, so
# nothing account-specific is committed to this repository.
#
# SAMPLE CODE — NOT FOR PRODUCTION USE. This script sets up a throwaway
# environment for the concepts in the accompanying AWS Database Blog post. It is
# not a secure or reusable infrastructure baseline: use your own IaC, hardened
# networking, and least-privilege roles for anything real. See README.md.
#
# This creates billable resources. Use non-production resources and
# least-privilege credentials, and run scripts/cleanup-aurora.sh when finished.
#
# The walkthrough connects as the Aurora master user (dbadmin) for brevity. That
# is a shortcut for a disposable cluster, not a pattern to copy: a real caller
# should use a dedicated role holding only the privileges it needs on the objects
# it touches. See the "Database privileges" section of README.md.
#
# If you already have a reachable PostgreSQL database, skip this script entirely
# and go straight to sql/postgresql/01_schema_and_data.sql.
#
# Required environment variables:
#   AWS_REGION                  e.g. eu-west-1
#   AVAILABILITY_ZONE           e.g. eu-west-1a
#   DB_SECURITY_GROUP_ID        security group attached to the database
#   CLIENT_SECURITY_GROUP_ID    security group attached to the client
#   DB_SUBNET_GROUP_NAME        existing DB subnet group
#   DB_CLUSTER_IDENTIFIER       name for the new cluster
#   DB_INSTANCE_IDENTIFIER      name for the new writer instance
#
# Optional:
#   ENGINE_VERSION              default 17.7
#   DB_INSTANCE_CLASS           default db.r6g.large
#   CREATE_CLIENT               set to "true" to launch an EC2 client
#   PRIVATE_SUBNET_ID           required when CREATE_CLIENT=true
#   EC2_INSTANCE_PROFILE_NAME   required when CREATE_CLIENT=true (for SSM access)
#   CLIENT_INSTANCE_TYPE        default c7g.large

set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

for var in AWS_REGION AVAILABILITY_ZONE DB_SECURITY_GROUP_ID CLIENT_SECURITY_GROUP_ID \
           DB_SUBNET_GROUP_NAME DB_CLUSTER_IDENTIFIER DB_INSTANCE_IDENTIFIER; do
  require "${var}"
done

ENGINE_VERSION="${ENGINE_VERSION:-17.7}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.r6g.large}"
CREATE_CLIENT="${CREATE_CLIENT:-false}"
CLIENT_INSTANCE_TYPE="${CLIENT_INSTANCE_TYPE:-c7g.large}"

echo "Region                : ${AWS_REGION}"
echo "Availability Zone     : ${AVAILABILITY_ZONE}"
echo "Engine version        : aurora-postgresql ${ENGINE_VERSION}"
echo "Writer instance class : ${DB_INSTANCE_CLASS}"
echo
echo "Verify that this engine version and instance class are available in your"
echo "Region before continuing:"
echo "  aws rds describe-db-engine-versions --region ${AWS_REGION} \\"
echo "      --engine aurora-postgresql --query 'DBEngineVersions[].EngineVersion'"
echo
read -r -p "Create billable resources now? [y/N] " confirm
[[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Aborted."; exit 0; }

# 1. Allow the client security group to connect to PostgreSQL.
# An existing rule is not an error: this is a precondition the walkthrough needs
# in place, not a resource it owns. Any other failure is still fatal.
echo "==> Authorizing port 5432 from ${CLIENT_SECURITY_GROUP_ID}"
if ingress_result=$(aws ec2 authorize-security-group-ingress \
      --region "${AWS_REGION}" \
      --group-id "${DB_SECURITY_GROUP_ID}" \
      --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${CLIENT_SECURITY_GROUP_ID},Description='PostgreSQL from migration client'}]" 2>&1); then
  echo "    rule added"
elif [[ "${ingress_result}" == *InvalidPermission.Duplicate* ]]; then
  echo "    rule already present, continuing"
  echo "    NOTE: cleanup-aurora.sh revokes this rule. If it existed before this"
  echo "          walkthrough, skip the revoke step when you tear down."
else
  echo "${ingress_result}" >&2
  exit 1
fi

# 2. Provision the Aurora PostgreSQL cluster.
# --manage-master-user-password stores the password in AWS Secrets Manager, so
# no credential is ever written to the shell history or to this repository.
#
# --storage-encrypted is stated explicitly. The console enables encryption at
# rest by default; the CLI does not, so omitting it here would create an
# unencrypted cluster. Encryption at rest can only be set when the cluster is
# created — turning it on later requires taking a snapshot and restoring it into
# a new encrypted cluster. Without a --kms-key-id this uses the AWS managed key
# for RDS (aws/rds); pass a customer managed key if you need to control the key
# policy or rotation. Snapshots inherit the cluster's encryption setting.
echo "==> Creating cluster ${DB_CLUSTER_IDENTIFIER}"
aws rds create-db-cluster \
  --region "${AWS_REGION}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}" \
  --engine aurora-postgresql \
  --engine-version "${ENGINE_VERSION}" \
  --master-username dbadmin \
  --manage-master-user-password \
  --storage-encrypted \
  --vpc-security-group-ids "${DB_SECURITY_GROUP_ID}" \
  --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" \
  --availability-zones "${AVAILABILITY_ZONE}"

# 3. Provision the Aurora writer instance.
# --no-publicly-accessible is stated rather than inherited. A writer in a private
# DB subnet group would not get a public address anyway, but saying so keeps the
# posture independent of the subnet group and of any account-level default, and
# makes the intent unambiguous for a reader who copies this command.
echo "==> Creating writer ${DB_INSTANCE_IDENTIFIER}"
aws rds create-db-instance \
  --region "${AWS_REGION}" \
  --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}" \
  --db-instance-class "${DB_INSTANCE_CLASS}" \
  --engine aurora-postgresql \
  --no-publicly-accessible \
  --availability-zone "${AVAILABILITY_ZONE}"

echo "==> Waiting for the writer to become available"
aws rds wait db-instance-available \
  --region "${AWS_REGION}" \
  --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}"

# 4. Optionally provision an EC2 client in the same Availability Zone.
# Co-locating the client removes cross-AZ network time from the benchmark.
if [[ "${CREATE_CLIENT}" == "true" ]]; then
  require PRIVATE_SUBNET_ID
  require EC2_INSTANCE_PROFILE_NAME

  echo "==> Launching ${CLIENT_INSTANCE_TYPE} benchmark client"
  # --metadata-options is explicit rather than inherited: Amazon Linux 2023 AMIs
  # are registered with ImdsSupport=v2.0, so instances launched from them already
  # default to HttpTokens=required, but stating it keeps the posture independent
  # of the AMI and of any account-level default. Requests to IMDS then need a
  # token:
  #   TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  #     -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  #   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  #     http://169.254.169.254/latest/meta-data/instance-type
  aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --instance-type "${CLIENT_INSTANCE_TYPE}" \
    --subnet-id "${PRIVATE_SUBNET_ID}" \
    --security-group-ids "${CLIENT_SECURITY_GROUP_ID}" \
    --iam-instance-profile "Name=${EC2_INSTANCE_PROFILE_NAME}" \
    --placement "AvailabilityZone=${AVAILABILITY_ZONE}" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bi-migration-bench}]'

  echo
  echo "Connect with SSM Session Manager (no SSH key needed):"
  echo "  aws ssm start-session --region ${AWS_REGION} --target YOUR_EC2_INSTANCE_ID"
fi

ENDPOINT=$(aws rds describe-db-clusters \
  --region "${AWS_REGION}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}" \
  --query 'DBClusters[0].Endpoint' --output text)

SECRET_ARN=$(aws rds describe-db-clusters \
  --region "${AWS_REGION}" \
  --db-cluster-identifier "${DB_CLUSTER_IDENTIFIER}" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)

cat <<EOF

Cluster endpoint : ${ENDPOINT}
Master secret    : ${SECRET_ARN}

Retrieve the password and build a connection string. The ARN is assigned in
single quotes deliberately: RDS-managed secret ARNs contain "rds!cluster-", and
an unquoted or double-quoted "!" triggers bash history expansion, which fails
with 'event not found' and silently drops the argument. Only single quotes and
backslashes suppress it.

  SECRET_ARN='${SECRET_ARN}'

  PGPASSWORD=\$(aws secretsmanager get-secret-value --region ${AWS_REGION} \\
      --secret-id "\$SECRET_ARN" --query SecretString --output text \\
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

  export PGCONNSTR="Host=${ENDPOINT};Database=postgres;Username=dbadmin;Password=\${PGPASSWORD};SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem"

Then load the schema and routines:

  psql "host=${ENDPOINT} dbname=postgres user=dbadmin" -v ON_ERROR_STOP=1 -f sql/postgresql/01_schema_and_data.sql
  psql "host=${ENDPOINT} dbname=postgres user=dbadmin" -v ON_ERROR_STOP=1 -f sql/postgresql/02_sp_dashboard_temp.sql
  psql "host=${ENDPOINT} dbname=postgres user=dbadmin" -v ON_ERROR_STOP=1 -f sql/postgresql/03_fn_dashboard_json.sql
EOF
