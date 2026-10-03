#!/usr/bin/env bash
# Bootstrap one AWS account for keyless deploys from GitHub Actions.
#
# Creates or updates, in the account your current credentials belong to:
#
#   OIDC provider  token.actions.githubusercontent.com   GitHub Actions sign-in
#
#   Platform (Terraform)
#     platform-deploy-role    assumed by PLATFORM_REPOS via OIDC
#                             policy: platform-deploy-policy (its ONLY policy)
#   Apps (SAM / CloudFormation) — skipped when APP_REPOS is empty
#     app-deploy-role         assumed by APP_REPOS via OIDC; can only drive
#                             CloudFormation and pass app-cfn-exec-role to it
#     app-cfn-exec-role       assumed by CloudFormation; creates the app resources
#   Test
#     lambda-test-role        logs-only role for hand-made Lambdas (optional)
#   Network — only when you answer yes (SECURITY_GROUP=yes)
#     app-default-sg          security group for VPC-attached functions, in one
#                             VPC: all egress, no ingress. Published to SSM:
#                             /default/vpc/security_group_id  the group's id
#                             /default/vpc/subnet_ids         the VPC's subnets
#
#   GitHub (with the gh CLI; CONFIGURE_GITHUB=false to skip)
#     each repository's environments, created if missing, with the variables
#     AWS_ACCOUNT_ID, AWS_REGION and the ARNs of the roles it may assume
#   Locally, in OUTPUTS_DIR (default ./outputs)
#     root.hcl and GitHub Actions workflows filled in for every account applied so
#     far, ready to copy into the repositories
#
# Nothing else in AWS: no VPC, subnet, bucket or function.
#
# Usage:
#   ./bootstrap-account.sh [--dry-run] [--yes] [<github-environment>...]
#
#   --dry-run   print the plan and every policy document; change nothing
#   --yes       unattended: no questions, no confirmation (for automation)
#
# Anything not given as an argument or in the environment is asked for
# interactively, every run; a value in bootstrap.env is the default, so Enter
# confirms it. You are offered to save new answers.
#
# The environments apply to both roles unless PLATFORM_ENVIRONMENTS or
# APP_ENVIRONMENTS is set. Configuration: see bootstrap.env.example.
#
# Safe to re-run. Existing resources are kept, trust policies are rewritten, and
# each permissions policy gets a new default version only when its JSON changed.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(dirname "$0")/lib/config.sh"
# shellcheck source=lib/github.sh
source "$(dirname "$0")/lib/github.sh"

DRY_RUN=0
ASSUME_YES=0
env_args=()
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1; INTERACTIVE=0 ;;   # unattended: never prompt
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option ${arg}" ;;
    *)         env_args+=("${arg}") ;;
  esac
done

command -v python3 >/dev/null || die "python3 is required"
command -v aws     >/dev/null || die "the AWS CLI is required"

# The account first, so every question below can say which account it is about.
if ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  HAVE_CREDENTIALS=1
  account_label="${ACCOUNT_ID}"
  alias="$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || true)"
  [[ "${alias}" == "None" ]] && alias=""
  [[ -n "${alias}" ]] && account_label="${ACCOUNT_ID} (${alias})"
  export ACCOUNT_ALIAS="${alias}"
elif (( DRY_RUN )); then
  ACCOUNT_ID="${ACCOUNT_ID:-123456789012}"
  HAVE_CREDENTIALS=0
  account_label="${ACCOUNT_ID} (placeholder — no credentials)"
else
  die "no AWS credentials — run under aws-vault, an SSO profile, or similar"
fi
export ACCOUNT_ID

# --- Ask, or confirm what the config file says --------------------------------
if (( INTERACTIVE )); then
  echo "Bootstrapping account ${account_label}. Enter keeps the value in [brackets] (Ctrl-C to stop)."
  echo
fi
ask GITHUB_ORG "GitHub organisation (or user) that owns the repositories" "$(guess_github_org)"
if [[ -z "${PLATFORM_REPOS:-}" && -n "${REPOS:-}" ]]; then
  export PLATFORM_REPOS="${REPOS}"
  # shellcheck disable=SC2034  # read by ask, so the old name is confirmed too
  [[ -n "${CONFIG_FILE_REPOS+set}" ]] && CONFIG_FILE_PLATFORM_REPOS="${REPOS}"
fi
ask PLATFORM_REPOS "Repositories that run Terraform (space-separated, without the org)"
ask APP_REPOS "Repositories that deploy SAM / CloudFormation apps (none: no app roles)" "" optional

if (( ${#env_args[@]} )); then
  : "${PLATFORM_ENVIRONMENTS:=${env_args[*]}}"
  : "${APP_ENVIRONMENTS:=${env_args[*]}}"
fi
if (( ! INTERACTIVE )) && [[ -z "${PLATFORM_ENVIRONMENTS:-}" ]]; then
  die "name the GitHub environment(s) for account ${ACCOUNT_ID} as arguments, e.g. $0 dev"
fi
ask PLATFORM_ENVIRONMENTS "GitHub environment(s) that may run Terraform in account ${ACCOUNT_ID}"
if [[ -n "${APP_REPOS}" ]]; then
  ask APP_ENVIRONMENTS "GitHub environment(s) that may deploy apps in account ${ACCOUNT_ID}" "${PLATFORM_ENVIRONMENTS}"
fi
ask ALLOWED_REGIONS "Region(s) the roles may act in" "us-east-1"
export PLATFORM_ENVIRONMENTS APP_ENVIRONMENTS="${APP_ENVIRONMENTS:-}"

# The security group is per account: whether to create one, and in which VPC.
# It goes in the first allowed region, the one AWS_REGION names in GitHub.
read -r -a allowed_regions <<<"${ALLOWED_REGIONS}"
SG_REGION="${allowed_regions[0]}"
ask SECURITY_GROUP "Create a security group for VPC-attached functions in account ${ACCOUNT_ID}? (yes/no)" "no"
WITH_SG=0; is_yes "${SECURITY_GROUP}" && WITH_SG=1
if (( WITH_SG )); then
  default_vpc=""
  if (( HAVE_CREDENTIALS )); then
    default_vpc="$(aws ec2 describe-vpcs --region "${SG_REGION}" --filters Name=is-default,Values=true \
                     --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
    [[ "${default_vpc}" == "None" ]] && default_vpc=""
  else
    default_vpc="vpc-00000000000000000"   # placeholder for a dry run without credentials
  fi
  ask SECURITY_GROUP_VPC_ID "VPC for the security group, in ${SG_REGION} (default: the default VPC)" "${default_vpc}"
fi

# Environments and the security group are per account, so they are not offered
# for saving.
saveable=()
for var in "${ANSWERED[@]+"${ANSWERED[@]}"}"; do
  [[ "${var}" == *_ENVIRONMENTS || "${var}" == SECURITY_GROUP* ]] || saveable+=("${var}")
done
ANSWERED=("${saveable[@]+"${saveable[@]}"}")

config_defaults
WITH_APPS=0; [[ -n "${APP_REPOS}" ]] && WITH_APPS=1

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
policy_arn() { echo "arn:aws:iam::${ACCOUNT_ID}:policy/$1"; }

# --- Render everything up front, so a bad template fails before any change -----
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
render permissions platform     > "${WORK}/platform-permissions.json"
render trust platform           > "${WORK}/platform-trust.json"
render service-trust lambda     > "${WORK}/lambda-trust.json"
if (( WITH_APPS )); then
  render permissions app        > "${WORK}/app-permissions.json"
  render trust app              > "${WORK}/app-trust.json"
  render permissions app-exec   > "${WORK}/app-exec-permissions.json"
  render service-trust cloudformation > "${WORK}/app-exec-trust.json"
fi

# IAM size limits count characters excluding whitespace.
size() { tr -d '[:space:]' < "$1" | wc -c | tr -d ' '; }
for f in "${WORK}"/*-permissions.json; do
  (( $(size "$f") <= 6144 )) || die "$(basename "$f") is $(size "$f") characters; IAM allows 6144"
done
trust_warnings=()
for f in "${WORK}"/platform-trust.json "${WORK}"/app-trust.json; do
  [[ -f "$f" ]] || continue
  if (( $(size "$f") > 2048 )); then
    trust_warnings+=("$(basename "$f" .json) is $(size "$f") characters, over IAM's default 2048: raise the 'Role trust policy length' quota (max 4096) or list fewer repos/environments")
  fi
done

# Managed policies attached to <role> today, other than <keep-arn>.
others_attached() {
  (( HAVE_CREDENTIALS )) || return 0
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || return 0
  aws iam list-attached-role-policies --role-name "$1" \
    --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | grep -vxF "$2" || true
}

# The security group by name in its VPC, the VPC's subnets, and what an SSM
# parameter holds today - and whether this bootstrap is the one that wrote it.
existing_sg() {
  (( HAVE_CREDENTIALS )) || return 0
  aws ec2 describe-security-groups --region "${SG_REGION}" \
    --filters "Name=vpc-id,Values=${SECURITY_GROUP_VPC_ID}" "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text | grep -vx None || true
}
# vpc_subnets prints "<private|public> <ids, comma-separated and sorted>". Only the
# private subnets when the VPC has any - a function in a public subnet has no
# internet access, since Lambda never gives it a public IP - and every subnet
# otherwise, which is the default VPC's case.
vpc_subnets() {
  (( HAVE_CREDENTIALS )) || { echo "private subnet-00000000000000000,subnet-11111111111111111"; return 0; }
  python3 - \
    "$(aws ec2 describe-subnets --region "${SG_REGION}" --filters "Name=vpc-id,Values=${SECURITY_GROUP_VPC_ID}" --output json)" \
    "$(aws ec2 describe-route-tables --region "${SG_REGION}" --filters "Name=vpc-id,Values=${SECURITY_GROUP_VPC_ID}" --output json)" <<'PY'
import json, sys

subnets = [s["SubnetId"] for s in json.loads(sys.argv[1])["Subnets"]]
tables = json.loads(sys.argv[2])["RouteTables"]
main = next((t for t in tables if any(a.get("Main") for a in t["Associations"])), {"Routes": []})


def table(subnet):
    return next((t for t in tables if any(a.get("SubnetId") == subnet for a in t["Associations"])), main)


def public(subnet):
    return any(
        r.get("GatewayId", "").startswith("igw-")
        and (r.get("DestinationCidrBlock") == "0.0.0.0/0" or r.get("DestinationIpv6CidrBlock") == "::/0")
        for r in table(subnet)["Routes"]
    )


private = sorted(s for s in subnets if not public(s))
print("private" if private else "public", ",".join(private or sorted(subnets)))
PY
}
param_value() {
  (( HAVE_CREDENTIALS )) || return 0
  aws ssm get-parameter --region "${SG_REGION}" --name "$1" \
    --query Parameter.Value --output text 2>/dev/null || true
}
param_is_ours() {
  [[ "$(aws ssm list-tags-for-resource --region "${SG_REGION}" --resource-type Parameter --resource-id "$1" \
          --query "TagList[?Key=='ManagedBy'].Value" --output text 2>/dev/null)" == aws-account-bootstrap ]]
}

if (( WITH_SG && HAVE_CREDENTIALS )); then
  aws ec2 describe-vpcs --region "${SG_REGION}" --vpc-ids "${SECURITY_GROUP_VPC_ID}" >/dev/null 2>&1 ||
    die "VPC ${SECURITY_GROUP_VPC_ID} not found in ${SG_REGION} in account ${ACCOUNT_ID}"
fi

# --- Plan ---------------------------------------------------------------------
plan_role() {  # plan_role <role> <policy> <permissions-file> <who-assumes>
  echo "  IAM role       $1"
  echo "                 assumed by $4"
  echo "                 policy $2 ($(size "$3") / 6144 characters)"
  local arn
  while read -r arn; do
    [[ -n "${arn}" ]] && echo "  DETACH       ${arn}  (currently on $1)"
  done < <(others_attached "$1" "$(policy_arn "$2")")
}

read -r -a platform_repos <<<"${PLATFORM_REPOS}"
echo
echo "Account ${account_label}"
echo "  OIDC provider  ${OIDC_HOST}"
echo
echo " Platform"
plan_role "${PLATFORM_ROLE_NAME}" "${PLATFORM_POLICY_NAME}" "${WORK}/platform-permissions.json" \
  "${#platform_repos[@]} repo(s) in ${GITHUB_ORG}, environment(s): ${PLATFORM_ENVIRONMENTS}"
if (( WITH_APPS )); then
  read -r -a app_repos <<<"${APP_REPOS}"
  echo
  echo " Apps"
  plan_role "${APP_ROLE_NAME}" "${APP_POLICY_NAME}" "${WORK}/app-permissions.json" \
    "${#app_repos[@]} repo(s) in ${GITHUB_ORG}, environment(s): ${APP_ENVIRONMENTS}"
  plan_role "${APP_EXEC_ROLE_NAME}" "${APP_EXEC_POLICY_NAME}" "${WORK}/app-exec-permissions.json" \
    "cloudformation.amazonaws.com in this account, when passed by ${APP_ROLE_NAME}"
fi
if [[ -n "${LAMBDA_ROLE_NAME}" ]]; then
  echo
  echo " Test"
  echo "  IAM role       ${LAMBDA_ROLE_NAME}  AWSLambdaBasicExecutionRole, assumable by Lambda in this account"
fi
# plan_param <name> <value, empty when only known after apply> <what that value is>
plan_param() {
  local now; now="$(param_value "$1")"
  if [[ -z "${now}" ]]; then
    echo "  SSM parameter  $1 = ${2:-$3}  (to create)"
  elif [[ "${now}" == "$2" ]]; then
    echo "  SSM parameter  $1 = ${now}  (up to date)"
  elif param_is_ours "$1"; then
    echo "  SSM parameter  $1 = ${2:-$3}  (to update, was ${now})"
  else
    echo "  SSM parameter  $1 = ${now}"
    echo "  WARNING: not written by aws-account-bootstrap, so it is left as it is. Delete it first to hand it over."
  fi
}

if (( WITH_SG )); then
  sg_now="$(existing_sg)"
  read -r subnet_kind subnets <<<"$(vpc_subnets)"
  echo
  echo " Network"
  echo "  Security group ${SECURITY_GROUP_NAME} in ${SECURITY_GROUP_VPC_ID} (${SG_REGION}): all egress, no ingress"
  if [[ -n "${sg_now}" ]]; then echo "                 exists, ${sg_now}"; else echo "                 to create"; fi
  if [[ -n "${VPC_SSM_PREFIX}" ]]; then
    if [[ -n "${subnets}" ]]; then
      plan_param "${VPC_SSM_PREFIX}/subnet_ids" "${subnets}" ""
    else
      echo "  WARNING: ${SECURITY_GROUP_VPC_ID} has no subnets, so ${VPC_SSM_PREFIX}/subnet_ids is not published"
    fi
    plan_param "${VPC_SSM_PREFIX}/security_group_id" "${sg_now}" "the new group's id"
  fi
  if [[ -n "${subnets}" && "${subnet_kind}" == "public" ]]; then
    echo "  NOTE: ${SECURITY_GROUP_VPC_ID} has no private subnets, so all of its subnets are published. Lambda never"
    echo "        gives a function a public IP, so one attached to them reaches AWS services but not the internet."
  fi
fi
for w in "${trust_warnings[@]+"${trust_warnings[@]}"}"; do echo; echo "  WARNING: ${w}"; done
github_sync plan

if (( DRY_RUN )); then
  for f in "${WORK}"/*.json; do echo; echo "── $(basename "$f")"; cat "$f"; done
  offer_to_save
  exit 0
fi

if (( ! ASSUME_YES )); then
  echo
  read -r -p "Proceed? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || { offer_to_save; exit 1; }
fi
offer_to_save
echo

# --- Apply --------------------------------------------------------------------
# shellcheck disable=SC2054  # commas are AWS CLI shorthand, not array separators
TAGS=(Key=ManagedBy,Value=aws-account-bootstrap)

# IAM descriptions accept only printable Latin-1, so every one below is plain ASCII.
ensure_role() {  # ensure_role <name> <description> <trust-file>
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "file://$3"
    echo "  $1: exists, trust policy rewritten"
  else
    aws iam create-role --role-name "$1" --description "$2" --max-session-duration 3600 \
      --assume-role-policy-document "file://$3" --tags "${TAGS[@]}" >/dev/null
    echo "  $1: created"
  fi
}

ensure_policy() {  # ensure_policy <name> <description> <permissions-file>
  local arn; arn="$(policy_arn "$1")"
  if aws iam get-policy --policy-arn "${arn}" >/dev/null 2>&1; then
    local version live old oldest
    version="$(aws iam get-policy --policy-arn "${arn}" --query Policy.DefaultVersionId --output text)"
    live="$(aws iam get-policy-version --policy-arn "${arn}" --version-id "${version}" \
              --query PolicyVersion.Document --output json | render canonical -)"
    if [[ "${live}" == "$(render canonical "$3")" ]]; then
      echo "  $1: up to date"
      return
    fi
    # A managed policy keeps at most five versions; drop the oldest non-default one.
    # shellcheck disable=SC2016  # the backticks are a JMESPath literal
    old="$(aws iam list-policy-versions --policy-arn "${arn}" \
             --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
    if (( $(wc -w <<<"${old}") >= 4 )); then
      oldest="$(tr '\t' '\n' <<<"${old}" | sort -V | head -1)"
      aws iam delete-policy-version --policy-arn "${arn}" --version-id "${oldest}"
    fi
    aws iam create-policy-version --policy-arn "${arn}" --policy-document "file://$3" \
      --set-as-default >/dev/null
    echo "  $1: new default version (previous kept for rollback)"
  else
    aws iam create-policy --policy-name "$1" --description "$2" \
      --policy-document "file://$3" --tags "${TAGS[@]}" >/dev/null
    echo "  $1: created"
  fi
}

# deploy_role <role> <role-description> <trust-file> <policy> <policy-description> <permissions-file>
# Makes <policy> the role's only managed policy. It is attached before anything is
# detached, so the role is never left with nothing; and everything else goes,
# because any one policy left behind re-grants what the scoped one leaves out.
deploy_role() {
  local role="$1" policy="$4" arn
  ensure_policy "${policy}" "$5" "$6"
  ensure_role "${role}" "$2" "$3"
  aws iam attach-role-policy --role-name "${role}" --policy-arn "$(policy_arn "${policy}")"
  while read -r arn; do
    [[ -z "${arn}" ]] && continue
    aws iam detach-role-policy --role-name "${role}" --policy-arn "${arn}"
    echo "  ${role}: detached ${arn##*/}"
  done < <(others_attached "${role}" "$(policy_arn "${policy}")")
  # Inline policies are reported, never deleted: they cannot be recovered.
  for name in $(aws iam list-role-policies --role-name "${role}" --query 'PolicyNames[]' --output text); do
    echo "  WARNING: ${role} still has inline policy '${name}', which grants its own permissions" >&2
  done
}

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  echo "  OIDC provider: exists"
else
  # AWS no longer validates the thumbprint for GitHub's issuer, so none is passed.
  aws iam create-open-id-connect-provider --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com --tags "${TAGS[@]}" >/dev/null
  echo "  OIDC provider: created"
fi

for w in "${trust_warnings[@]+"${trust_warnings[@]}"}"; do echo "  WARNING: ${w}" >&2; done

deploy_role "${PLATFORM_ROLE_NAME}" "Platform deploy role (Terraform), assumed via GitHub OIDC" \
  "${WORK}/platform-trust.json" \
  "${PLATFORM_POLICY_NAME}" "Scoped platform deploy permissions, managed by aws-account-bootstrap" \
  "${WORK}/platform-permissions.json"

if (( WITH_APPS )); then
  # The execution role first: the deploy role's policy names it.
  deploy_role "${APP_EXEC_ROLE_NAME}" "CloudFormation execution role for application stacks" \
    "${WORK}/app-exec-trust.json" \
    "${APP_EXEC_POLICY_NAME}" "What application stacks may create, managed by aws-account-bootstrap" \
    "${WORK}/app-exec-permissions.json"
  deploy_role "${APP_ROLE_NAME}" "Application deploy role (SAM), assumed via GitHub OIDC" \
    "${WORK}/app-trust.json" \
    "${APP_POLICY_NAME}" "Drive CloudFormation with the app execution role, managed by aws-account-bootstrap" \
    "${WORK}/app-permissions.json"
fi

if [[ -n "${LAMBDA_ROLE_NAME}" ]]; then
  ensure_role "${LAMBDA_ROLE_NAME}" "Execution role for hand-made test Lambdas. Logs only." "${WORK}/lambda-trust.json"
  aws iam attach-role-policy --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi

# No ingress rule, and the default egress rule a new group gets (all traffic,
# 0.0.0.0/0) left in place: nothing is restricted yet.
#
# publish_param <name> <type> <value> <description>. A parameter this bootstrap
# wrote (tagged ManagedBy) is kept current; one written by anything else is never
# overwritten, because something else depends on what it says.
publish_param() {
  local now; now="$(param_value "$1")"
  if [[ -z "${now}" ]]; then
    aws ssm put-parameter --region "${SG_REGION}" --name "$1" --type "$2" --value "$3" \
      --description "$4" --tags "${TAGS[@]}" >/dev/null
    echo "  $1: created"
  elif [[ "${now}" == "$3" ]]; then
    echo "  $1: up to date"
  elif param_is_ours "$1"; then
    aws ssm put-parameter --region "${SG_REGION}" --name "$1" --type "$2" --value "$3" --overwrite >/dev/null
    echo "  $1: updated (was ${now})"
  else
    echo "  WARNING: $1 holds ${now} and was not written by aws-account-bootstrap; left as it is" >&2
  fi
}

SG_ID=""
if (( WITH_SG )); then
  SG_ID="$(existing_sg)"
  if [[ -n "${SG_ID}" ]]; then
    echo "  ${SECURITY_GROUP_NAME}: exists (${SG_ID})"
  else
    SG_ID="$(aws ec2 create-security-group --region "${SG_REGION}" \
      --group-name "${SECURITY_GROUP_NAME}" --vpc-id "${SECURITY_GROUP_VPC_ID}" \
      --description "Security group for VPC-attached functions. All egress, no ingress." \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=ManagedBy,Value=aws-account-bootstrap},{Key=Name,Value=${SECURITY_GROUP_NAME}}]" \
      --query GroupId --output text)"
    echo "  ${SECURITY_GROUP_NAME}: created (${SG_ID})"
  fi
  if [[ -n "${VPC_SSM_PREFIX}" ]]; then
    read -r _ subnets <<<"$(vpc_subnets)"
    if [[ -n "${subnets}" ]]; then
      publish_param "${VPC_SSM_PREFIX}/subnet_ids" StringList "${subnets}" \
        "Subnets of ${SECURITY_GROUP_VPC_ID} for VPC-attached functions: the private ones, or all if none are (aws-account-bootstrap)"
    else
      echo "  WARNING: ${SECURITY_GROUP_VPC_ID} has no subnets; ${VPC_SSM_PREFIX}/subnet_ids not published" >&2
    fi
    publish_param "${VPC_SSM_PREFIX}/security_group_id" String "${SG_ID}" \
      "Security group for VPC-attached functions (aws-account-bootstrap)"
  fi
fi

# After the roles, so no variable ever points at a role that failed to appear.
github_sync apply

echo
echo "Done:"
echo "  ${OIDC_ARN}"
for role in "${PLATFORM_ROLE_NAME}" \
            "$( (( WITH_APPS )) && echo "${APP_ROLE_NAME}")" \
            "$( (( WITH_APPS )) && echo "${APP_EXEC_ROLE_NAME}")" \
            "${LAMBDA_ROLE_NAME}"; do
  [[ -n "${role}" ]] && echo "  arn:aws:iam::${ACCOUNT_ID}:role/${role}"
done
[[ -n "${SG_ID}" ]] && echo "  ${SG_ID} (${SECURITY_GROUP_NAME}, ${SECURITY_GROUP_VPC_ID})"

echo
echo "Ready to copy into the repositories:"
python3 "${LIB_DIR}/outputs.py" record
python3 "${LIB_DIR}/outputs.py" render
(( GITHUB_FAILURES == 0 )) || die "the roles are in place, but ${GITHUB_FAILURES} GitHub step(s) failed; see the warnings above"
exit 0
