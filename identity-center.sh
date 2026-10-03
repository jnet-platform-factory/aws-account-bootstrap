#!/usr/bin/env bash
# Create or update the IAM Identity Center permission sets defined in
# identity-center/permission-sets.json. Run it in the AWS Organizations management
# account, or in the account delegated to administer IAM Identity Center.
#
# For each permission set: its description and session duration, the AWS managed
# policies attached to it (any others are detached), and its inline policy from
# identity-center/policies/. A permission set that changed is re-provisioned to
# every account it is already assigned in, so the change reaches those accounts.
#
# It never deletes a permission set, and never creates or changes an assignment —
# which group gets which permission set in which account is set in the console or
# with `aws sso-admin create-account-assignment`.
#
# Usage:
#   ./permission-sets.sh [--dry-run] [--yes]
#
#   --dry-run   print the plan and every inline policy; change nothing
#   --yes       no confirmation (for automation)
#
# IAM Identity Center lives in one region. If it is not your profile's region,
# set SSO_REGION.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFS_DIR="${ROOT_DIR}/identity-center"
die() { echo "error: $*" >&2; exit 1; }
canonical() { python3 "${ROOT_DIR}/lib/render.py" canonical "$@"; }

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument ${arg}" ;;
  esac
done

command -v python3 >/dev/null || die "python3 is required"
command -v aws     >/dev/null || die "the AWS CLI is required"

sso() { aws sso-admin ${SSO_REGION:+--region "${SSO_REGION}"} "$@"; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# One line per permission set, checked before anything is called:
#   name <TAB> session duration <TAB> inline policy file or - <TAB> managed policy ARNs or - <TAB> description
python3 - "${DEFS_DIR}" > "${WORK}/definitions" <<'PY'
import json, re, sys
from pathlib import Path

defs = Path(sys.argv[1])
problems, names = [], set()
for s in json.load(open(defs / "permission-sets.json"))["permissionSets"]:
    name = s.get("name", "")
    if not re.fullmatch(r"[\w+=,.@-]{1,32}", name):
        problems.append(f"{name!r}: a name is 1-32 of letters, digits and +=,.@-_")
    if name in names:
        problems.append(f"{name}: defined twice")
    names.add(name)
    description = s.get("description", "")
    if not 1 <= len(description) <= 700 or not all(32 <= ord(c) < 127 for c in description):
        problems.append(f"{name}: the description must be 1-700 plain ASCII characters")
    duration = s.get("sessionDuration", "")
    m = re.fullmatch(r"PT(\d+)H", duration)
    if not m or not 1 <= int(m.group(1)) <= 12:
        problems.append(f"{name}: sessionDuration must be PT1H to PT12H, not {duration!r}")
    managed = s.get("managedPolicies", [])
    for arn in managed:
        if not arn.startswith("arn:aws:iam::aws:policy/"):
            problems.append(f"{name}: {arn} is not an AWS managed policy")
    inline = s.get("inlinePolicy")
    if inline:
        try:
            json.load(open(defs / inline))
        except (OSError, ValueError) as e:
            problems.append(f"{name}: inline policy {inline}: {e}")
    if not managed and not inline:
        problems.append(f"{name}: grants nothing - give it a managed or an inline policy")
    print("\t".join([name, duration, inline or "-", " ".join(managed) or "-", description]))
if problems:
    sys.exit("identity-center/permission-sets.json:\n  " + "\n  ".join(problems))
PY

# --- Where ---------------------------------------------------------------------
if INSTANCE="$(sso list-instances --query 'Instances[0].InstanceArn' --output text 2>/dev/null)" &&
   [[ -n "${INSTANCE}" && "${INSTANCE}" != "None" ]]; then
  HAVE_CREDENTIALS=1
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
elif (( DRY_RUN )); then
  HAVE_CREDENTIALS=0
  INSTANCE="(no credentials or no instance: every permission set is shown as new)"
  ACCOUNT_ID="-"
else
  die "no IAM Identity Center instance found. Run this in the management account (or the delegated
       administrator) with credentials for it, and set SSO_REGION if Identity Center is in another region"
fi

# name <TAB> ARN of every permission set that already exists
: > "${WORK}/existing"
if (( HAVE_CREDENTIALS )); then
  # A long list comes back one page per line, so split on both.
  while read -r arn; do
    [[ -z "${arn}" || "${arn}" == "None" ]] && continue
    name="$(sso describe-permission-set --instance-arn "${INSTANCE}" --permission-set-arn "${arn}" \
      --query 'PermissionSet.Name' --output text)"
    printf '%s\t%s\n' "${name}" "${arn}" >> "${WORK}/existing"
  done < <(sso list-permission-sets --instance-arn "${INSTANCE}" --query 'PermissionSets[]' --output text | tr '\t' '\n')
fi
existing_arn() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "${WORK}/existing"; }

# --- Plan, then apply ----------------------------------------------------------
# sync_set runs twice: in the plan phase it only says what would change; in the
# apply phase it says the same and does it.
PHASE=plan
CHANGES=0
change() {  # change <what> <command...>
  local what="$1"; shift
  CHANGES=$((CHANGES + 1))
  echo "    ${what}"
  if [[ "${PHASE}" == apply ]]; then "$@" >/dev/null || die "${what}: failed"; fi
}
has() { [[ " $1 " == *" $2 "* ]]; }   # has <space-separated list> <word>

sync_set() {  # sync_set <name> <duration> <inline> <managed> <description>
  local name="$1" duration="$2" inline="$3" managed="$4" description="$5"
  local arn now_managed="" now_inline="" policy="" before="${CHANGES}" accounts="" p
  [[ "${managed}" == "-" ]] && managed=""
  [[ "${inline}" != "-" ]] && policy="${DEFS_DIR}/${inline}"
  arn="$(existing_arn "${name}")"
  local ps=(--instance-arn "${INSTANCE}" --permission-set-arn "${arn}")

  echo "  Permission set  ${name}  (session ${duration})"
  if [[ -z "${arn}" ]]; then
    CHANGES=$((CHANGES + 1))
    echo "    create"
    if [[ "${PHASE}" == apply ]]; then
      arn="$(sso create-permission-set --instance-arn "${INSTANCE}" --name "${name}" \
        --description "${description}" --session-duration "${duration}" \
        --tags Key=ManagedBy,Value=aws-account-bootstrap \
        --query 'PermissionSet.PermissionSetArn' --output text)"
      ps=(--instance-arn "${INSTANCE}" --permission-set-arn "${arn}")
    fi
  else
    local now_duration now_description
    now_duration="$(sso describe-permission-set "${ps[@]}" --query 'PermissionSet.SessionDuration' --output text)"
    now_description="$(sso describe-permission-set "${ps[@]}" --query 'PermissionSet.Description' --output text)"
    if [[ "${now_duration}" != "${duration}" || "${now_description}" != "${description}" ]]; then
      change "update description and session duration (was ${now_duration})" \
        sso update-permission-set "${ps[@]}" --description "${description}" --session-duration "${duration}"
    fi
    now_managed="$(sso list-managed-policies-in-permission-set "${ps[@]}" \
      --query 'AttachedManagedPolicies[].Arn' --output text | tr '\t\n' '  ')"
    [[ "${now_managed}" == "None" ]] && now_managed=""
    now_inline="$(sso get-inline-policy-for-permission-set "${ps[@]}" --query 'InlinePolicy' --output text)"
    [[ "${now_inline}" == "None" ]] && now_inline=""
    accounts="$(sso list-accounts-for-provisioned-permission-set "${ps[@]}" --query 'AccountIds[]' --output text | tr '\t\n' '  ')"
    [[ "${accounts}" == "None" ]] && accounts=""
  fi

  for p in ${managed}; do
    if ! has "${now_managed}" "${p}"; then
      change "attach ${p##*/}" sso attach-managed-policy-to-permission-set "${ps[@]}" --managed-policy-arn "${p}"
    fi
  done
  for p in ${now_managed}; do
    if ! has "${managed}" "${p}"; then
      change "DETACH ${p##*/}  (not in permission-sets.json)" \
        sso detach-managed-policy-from-permission-set "${ps[@]}" --managed-policy-arn "${p}"
    fi
  done

  if [[ -n "${policy}" ]]; then
    if [[ -z "${now_inline}" || "$(canonical - <<<"${now_inline}")" != "$(canonical "${policy}")" ]]; then
      change "inline policy ${inline} ($(tr -d '[:space:]' < "${policy}" | wc -c | tr -d ' ') characters)" \
        sso put-inline-policy-to-permission-set "${ps[@]}" --inline-policy "file://${policy}"
    fi
  elif [[ -n "${now_inline}" ]]; then
    change "REMOVE the inline policy  (none in permission-sets.json)" \
      sso delete-inline-policy-from-permission-set "${ps[@]}"
  fi

  if [[ -n "${accounts}" ]] && (( CHANGES > before )); then
    read -r -a account_list <<<"${accounts}"
    change "re-provision to the ${#account_list[@]} account(s) it is assigned in" provision "${ps[@]}"
  fi
  (( CHANGES > before )) || echo "    up to date"
}

provision() {  # provision --instance-arn <i> --permission-set-arn <ps>; waits for it to finish
  local request status
  request="$(sso provision-permission-set "$@" --target-type ALL_PROVISIONED_ACCOUNTS \
    --query 'PermissionSetProvisioningStatus.RequestId' --output text)"
  for _ in $(seq 60); do
    status="$(sso describe-permission-set-provisioning-status --instance-arn "$2" \
      --provision-permission-set-request-id "${request}" --query 'PermissionSetProvisioningStatus.Status' --output text)"
    [[ "${status}" != "IN_PROGRESS" ]] && break
    sleep 2
  done
  [[ "${status}" == "SUCCEEDED" ]] || die "provisioning ${4##*/} ended ${status}"
}

run_phase() {
  local name duration inline managed description
  # fd 3, so nothing inside the loop can read the definitions as its stdin
  while IFS=$'\t' read -r -u 3 name duration inline managed description; do
    sync_set "${name}" "${duration}" "${inline}" "${managed}" "${description}"
  done 3< "${WORK}/definitions"
}

echo
echo "IAM Identity Center ${INSTANCE}"
echo "  account ${ACCOUNT_ID}${SSO_REGION:+, region ${SSO_REGION}}"
run_phase

others="$(cut -f1 "${WORK}/existing" | grep -vxF -f <(cut -f1 "${WORK}/definitions") | tr '\n' ' ' || true)"
[[ -n "${others}" ]] && { echo; echo "  Not managed here, left as they are: ${others}"; }

if (( DRY_RUN )); then
  while IFS=$'\t' read -r -u 3 _ _ inline _ _; do
    [[ "${inline}" == "-" ]] && continue
    echo; echo "── ${inline}"; cat "${DEFS_DIR}/${inline}"
    if (( HAVE_CREDENTIALS )); then
      findings="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
        --policy-document "file://${DEFS_DIR}/${inline}" \
        --query 'findings[].[findingType,issueCode]' --output text 2>&1 || true)"
      echo "   Access Analyzer: ${findings:-no findings}"
    fi
  done 3< "${WORK}/definitions"
  exit 0
fi

if (( CHANGES == 0 )); then echo; echo "Nothing to change."; exit 0; fi
if (( ! ASSUME_YES )); then
  echo
  read -r -p "Apply ${CHANGES} change(s)? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || exit 1
fi

echo
PHASE=apply
CHANGES=0
run_phase
echo
echo "done. Assign them in the console (IAM Identity Center > AWS accounts) or with"
echo "  aws sso-admin create-account-assignment --instance-arn ${INSTANCE} \\"
echo "    --target-type AWS_ACCOUNT --target-id <account id> --permission-set-arn <arn> \\"
echo "    --principal-type GROUP --principal-id <group id>"
