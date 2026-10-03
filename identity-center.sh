#!/usr/bin/env bash
# Create or update IAM Identity Center from the files in identity-center/: the
# permission sets, the groups, and which group gets which permission set in which
# account. Run it in the AWS Organizations management account, or in the account
# delegated to administer IAM Identity Center.
#
#   permission-sets.json   each permission set: description, session duration, the
#                          AWS managed policies attached to it (any others are
#                          detached) and its inline policy from policies/. One that
#                          changed is re-provisioned to every account it is assigned in.
#   groups/<Group>.json    a group, created if missing, and its assignments. Each names
#                          "account" (its name in AWS Organizations or its 12-digit ID)
#                          or "ou" (an OU path from the root, Management or Workloads/Prod,
#                          that holds exactly one active account). "formerly" lists
#                          older names: a group that does not exist yet takes over the
#                          former group with the most members, renamed in place, and
#                          the members of the other former groups are added to it.
#
# Re-running it changes nothing that already matches. It never deletes a permission
# set or a group, never removes an assignment, and never removes anyone from a group.
# Assignments in AWS that the files do not list are reported and left alone.
#
# Usage:
#   ./identity-center.sh [--dry-run] [--yes]
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
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument ${arg}" ;;
  esac
done

command -v python3 >/dev/null || die "python3 is required"
command -v aws     >/dev/null || die "the AWS CLI is required"

sso() { aws sso-admin     ${SSO_REGION:+--region "${SSO_REGION}"} "$@"; }
ids() { aws identitystore ${SSO_REGION:+--region "${SSO_REGION}"} "$@"; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# Everything is checked before anything is called. One line each:
#   definitions  name <TAB> session duration <TAB> inline policy file or - <TAB> managed policy ARNs or - <TAB> description
#   groups       name <TAB> description
#   formerly     group <TAB> an older name of it
#   assignments  group <TAB> account or ou <TAB> account name or ID, or OU path <TAB> permission set
python3 - "${DEFS_DIR}" "${WORK}" > "${WORK}/definitions" <<'PY'
import json, re, sys
from pathlib import Path

defs, work = Path(sys.argv[1]), Path(sys.argv[2])
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
            size = len("".join(open(defs / inline).read().split()))
            if size > 10240:  # Identity Center's limit, whitespace not counted
                problems.append(f"{name}: inline policy {inline} is {size} characters; the limit is 10240")
        except (OSError, ValueError) as e:
            problems.append(f"{name}: inline policy {inline}: {e}")
    if not managed and not inline:
        problems.append(f"{name}: grants nothing - give it a managed or an inline policy")
    print("\t".join([name, duration, inline or "-", " ".join(managed) or "-", description]))
if problems:
    sys.exit("identity-center/permission-sets.json:\n  " + "\n  ".join(problems))

groups, assignments, formerly = [], [], []
files = {p.stem for p in (defs / "groups").glob("*.json")}
for path in sorted((defs / "groups").glob("*.json")):
    where, group = f"identity-center/groups/{path.name}", path.stem
    if not re.fullmatch(r"[\w+=,.@ -]{1,128}", group):
        problems.append(f"{where}: a group name (the file name) is 1-128 of letters, digits, spaces and +=,.@-_")
    try:
        g = json.load(open(path))
    except ValueError as e:
        problems.append(f"{where}: {e}")
        continue
    description = g.get("description", "")
    if len(description) > 1024 or not all(32 <= ord(c) < 127 for c in description):
        problems.append(f"{where}: the description must be at most 1024 plain ASCII characters")
    groups.append(f"{group}\t{description}")
    old = g.get("formerly", [])
    if not isinstance(old, list):
        problems.append(f"{where}: formerly is a list of group names")
        old = []
    for name in old:
        if not isinstance(name, str) or not re.fullmatch(r"[\w+=,.@ -]{1,128}", name):
            problems.append(f"{where}: formerly {name!r} is not a group name")
        elif name in files:
            problems.append(f"{where}: formerly {name} is a group with its own file")
        elif name in (f for _, f in formerly):
            problems.append(f"{where}: formerly {name} is claimed by more than one group")
        else:
            formerly.append((group, name))
    seen = set()
    for a in g.get("assignments", []):
        targets = [(k, str(a[k]).strip().strip("/")) for k in ("account", "ou") if k in a]
        kind, target = targets[0] if len(targets) == 1 else ("", "")
        ps, label = a.get("permissionSet", ""), f"{'OU ' if kind == 'ou' else ''}{target}"
        if len(targets) > 1:
            problems.append(f"{where}: an assignment names both an account and an OU; give one")
        elif not target or "\t" in target:
            problems.append(f"{where}: an assignment without an account or an OU")
        elif ps not in names:
            problems.append(f"{where}: {ps!r} in {label} is not a permission set in permission-sets.json")
        elif (kind, target, ps) in seen:
            problems.append(f"{where}: {ps} in {label} is listed twice")
        else:
            seen.add((kind, target, ps))
            assignments.append(f"{group}\t{kind}\t{target}\t{ps}")
(work / "groups").write_text("".join(f"{l}\n" for l in groups))
(work / "assignments").write_text("".join(f"{l}\n" for l in assignments))
(work / "formerly").write_text("".join(f"{g}\t{n}\n" for g, n in formerly))
if problems:
    sys.exit("identity-center/groups:\n  " + "\n  ".join(problems))
PY

# --- Where ---------------------------------------------------------------------
if read -r INSTANCE IDENTITY_STORE < <(sso list-instances \
     --query 'Instances[0].[InstanceArn,IdentityStoreId]' --output text 2>/dev/null) &&
   [[ -n "${INSTANCE}" && "${INSTANCE}" != "None" ]]; then
  HAVE_CREDENTIALS=1
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
elif (( DRY_RUN )); then
  HAVE_CREDENTIALS=0
  INSTANCE="(no credentials or no instance: everything is shown as new)"
  IDENTITY_STORE="-"
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
existing_name() { awk -F'\t' -v a="$1" '$2 == a { print $1 }' "${WORK}/existing"; }

# The organization's accounts: id <TAB> name <TAB> state. Organizations reports
# State, and Status before it; whichever is there is used.
: > "${WORK}/accounts"
: > "${WORK}/accounts.error"
if (( HAVE_CREDENTIALS )); then
  aws organizations list-accounts --query 'Accounts[].[Id,Name,State,Status]' --output text \
    > "${WORK}/accounts" 2> "${WORK}/accounts.error" || true
fi

# Where each account sits, when an assignment names an OU: OU path <TAB> account ID,
# and OU path <TAB> nothing for every OU, so an empty one is known too. The path is the
# OU names from the root joined by /, and empty for the root itself.
walk_ous() {  # walk_ous <parent ID> <path>
  local id name
  [[ -n "$2" ]] && printf '%s\t\n' "$2"
  aws organizations list-accounts-for-parent --parent-id "$1" --query 'Accounts[].Id' --output text |
    tr '\t' '\n' | awk -v p="$2" 'NF && $1 != "None" { print p "\t" $1 }'
  while IFS=$'\t' read -r id name; do
    [[ -z "${id}" || "${id}" == "None" ]] && continue
    walk_ous "${id}" "${2:+$2/}${name}"
  done < <(aws organizations list-organizational-units-for-parent --parent-id "$1" \
             --query 'OrganizationalUnits[].[Id,Name]' --output text)
}
: > "${WORK}/placement"
: > "${WORK}/placement.error"
if (( HAVE_CREDENTIALS )) && awk -F'\t' '$2 == "ou" { f = 1 } END { exit !f }' "${WORK}/assignments"; then
  {
    root="$(aws organizations list-roots --query 'Roots[0].Id' --output text)" && walk_ous "${root}" ""
  } > "${WORK}/placement" 2> "${WORK}/placement.error" || true
fi

# Each assignment with its account resolved:
#   group <TAB> account ID (- without credentials) <TAB> label for the plan <TAB> permission set
python3 - "${WORK}" "${HAVE_CREDENTIALS}" > "${WORK}/resolved" <<'PY'
import re, sys
from pathlib import Path

work, have_credentials = Path(sys.argv[1]), sys.argv[2] == "1"
accounts = {}
for line in (work / "accounts").read_text().splitlines():
    if line.strip():
        id_, name, state, status = (line.split("\t") + ["None"] * 4)[:4]
        accounts[id_] = (name, state if state != "None" else status)
error = (work / "accounts.error").read_text().strip()
placement = [l.split("\t") for l in (work / "placement").read_text().splitlines() if "\t" in l]
placement_error = (work / "placement.error").read_text().strip()
problems, printed = [], set()
for line in (work / "assignments").read_text().splitlines():
    group, kind, account, ps = line.split("\t")
    where = f"groups/{group}.json: {ps} in {'OU ' if kind == 'ou' else ''}{account}"
    if not have_credentials:
        id_, label = "-", f"OU {account}" if kind == "ou" else account
    elif kind == "ou":
        if placement_error or not placement:
            problems.append(f"{where}: cannot look up OUs ({placement_error or 'no accounts listed'}); "
                            "give the account instead")
            continue
        ous = {p for p, _ in placement if p}
        if account not in ous:
            problems.append(f"{where}: no OU {account} (there are: {', '.join(sorted(ous)) or 'none'})")
            continue
        active = [i for p, i in placement if p == account and i and accounts.get(i, ("", "ACTIVE"))[1] == "ACTIVE"]
        if len(active) != 1:
            names = ", ".join(accounts.get(i, (i,))[0] for i in active)
            problems.append(f"{where}: OU {account} holds {len(active)} active accounts"
                            + (f" ({names}); name the account instead" if active else ""))
            continue
        id_ = active[0]
        label = f"{accounts[id_][0]} ({id_}), OU {account}" if id_ in accounts else f"{id_}, OU {account}"
    elif re.fullmatch(r"\d{12}", account):
        id_ = account
        if accounts and id_ not in accounts:
            problems.append(f"{where}: no account {id_} in this organization")
            continue
        label = f"{accounts[id_][0]} ({id_})" if id_ in accounts else id_
    elif not accounts:
        problems.append(f"{where}: cannot look up account names ({error or 'no accounts listed'}); "
                        "give the 12-digit account ID instead")
        continue
    else:
        matches = [i for i, (n, _) in accounts.items() if n == account]
        if len(matches) != 1:
            known = ", ".join(sorted(n for n, _ in accounts.values()))
            problems.append(f"{where}: " + (f"{len(matches)} accounts are named {account}; give the ID"
                            if matches else f"no account named {account} (there are: {known})"))
            continue
        id_ = matches[0]
        label = f"{account} ({id_})"
    if id_ in accounts and accounts[id_][1] != "ACTIVE":
        problems.append(f"{where}: account {id_} is {accounts[id_][1]}")
        continue
    if id_ != "-" and (group, id_, ps) in printed:   # the same account, named by name and by OU
        continue
    printed.add((group, id_, ps))
    print("\t".join([group, id_, label, ps]))
if problems:
    sys.exit("identity-center/groups:\n  " + "\n  ".join(problems))
PY
account_label() { awk -F'\t' -v i="$1" '$1 == i { print $2 " (" i ")"; f = 1 } END { if (!f) print i }' "${WORK}/accounts"; }

# name <TAB> ID <TAB> its name now, of every group in the files that already exists
# or takes over one of its former names
: > "${WORK}/group_ids"
lookup_group() {  # lookup_group <name>: its ID, or nothing if there is no such group
  local out
  if out="$(ids get-group-id --identity-store-id "${IDENTITY_STORE}" --query GroupId --output text \
       --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"$1\"}}" 2>&1)"; then
    echo "${out}"
  elif [[ "${out}" != *ResourceNotFoundException* ]]; then
    die "looking up group $1: ${out}"
  fi
}
group_id() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "${WORK}/group_ids"; }
group_now() { awk -F'\t' -v n="$1" '$1 == n { print $3 }' "${WORK}/group_ids"; }
member_ids() {  # member_ids <group ID>: the user IDs in it, one per line
  ids list-group-memberships --identity-store-id "${IDENTITY_STORE}" --group-id "$1" \
    --query 'GroupMemberships[].MemberId.UserId' --output text | tr '\t' '\n' | awk 'NF && $0 != "None"'
}

# group <TAB> account ID <TAB> permission set ARN of every assignment those groups have now
: > "${WORK}/current"
# group <TAB> ID <TAB> name of every former group whose members are added to it
: > "${WORK}/merge_from"
if (( HAVE_CREDENTIALS )); then
  while IFS=$'\t' read -r -u 3 name _; do
    id="$(lookup_group "${name}")" now="${name}"
    # Its former groups that still exist: ID <TAB> name <TAB> how many members
    : > "${WORK}/formers"
    while IFS=$'\t' read -r -u 5 _ old; do
      fid="$(lookup_group "${old}")"
      [[ -z "${fid}" ]] && continue
      members="$(member_ids "${fid}" | wc -l | tr -d ' ')"
      printf '%s\t%s\t%s\n' "${fid}" "${old}" "${members}" >> "${WORK}/formers"
    done 5< <(awk -F'\t' -v g="${name}" '$1 == g' "${WORK}/formerly")
    if [[ -z "${id}" && -s "${WORK}/formers" ]]; then
      # Take over the one with the most members, the first listed on a tie
      IFS=$'\t' read -r id now _ < <(sort -s -t$'\t' -k3,3nr "${WORK}/formers" | head -n 1)
    fi
    awk -F'\t' -v g="${name}" -v keep="${id}" '$1 != keep { print g "\t" $1 "\t" $2 }' \
      "${WORK}/formers" >> "${WORK}/merge_from"
    [[ -z "${id}" ]] && continue
    printf '%s\t%s\t%s\n' "${name}" "${id}" "${now}" >> "${WORK}/group_ids"
    sso list-account-assignments-for-principal --instance-arn "${INSTANCE}" \
      --principal-type GROUP --principal-id "${id}" \
      --query 'AccountAssignments[].[AccountId,PermissionSetArn]' --output text |
      awk -v g="${name}" 'NF == 2 { print g "\t" $1 "\t" $2 }' >> "${WORK}/current"
  done 3< "${WORK}/groups"
fi

# --- Plan, then apply ----------------------------------------------------------
# Each sync_ function runs twice: in the plan phase it only says what would change;
# in the apply phase it says the same and does it.
PHASE=plan
CHANGES=0
change() {  # change <what> <command...>
  local what="$1"; shift
  CHANGES=$((CHANGES + 1))
  echo "    ${what}"
  if [[ "${PHASE}" == apply ]]; then "$@" >/dev/null || die "${what}: failed"; fi
}
has() { [[ " $1 " == *" $2 "* ]]; }   # has <space-separated list> <word>

wait_for() {  # wait_for <what> <sso describe command...>: polls until it is no longer IN_PROGRESS
  local what="$1" status=""; shift
  for _ in $(seq 60); do
    status="$(sso "$@" --output text)"
    [[ "${status}" != "IN_PROGRESS" ]] && break
    sleep 2
  done
  [[ "${status}" == "SUCCEEDED" ]] || die "${what} ended ${status}"
}

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
      printf '%s\t%s\n' "${name}" "${arn}" >> "${WORK}/existing"   # for the assignments
      ps=(--instance-arn "${INSTANCE}" --permission-set-arn "${arn}")
    fi
  else
    local now_duration now_description
    now_duration="$(sso describe-permission-set "${ps[@]}" --query 'PermissionSet.SessionDuration' --output text)"
    now_description="$(sso describe-permission-set "${ps[@]}" --query 'PermissionSet.Description' --output text)"
    local what=()
    [[ "${now_description}" != "${description}" ]] && what+=("description")
    [[ "${now_duration}" != "${duration}" ]] && what+=("session duration (was ${now_duration})")
    if (( ${#what[@]} )); then
      change "update $(printf '%s\n' "${what[@]}" | paste -sd, - | sed 's/,/ and /')" \
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
    change "re-provision where it is assigned: $(for a in "${account_list[@]}"; do account_label "${a}"; done |
      paste -sd, - | sed 's/,/, /g')" provision "${ps[@]}"
  fi
  (( CHANGES > before )) || echo "    up to date"
}

provision() {  # provision --instance-arn <i> --permission-set-arn <ps>; waits for it to finish
  local request
  request="$(sso provision-permission-set "$@" --target-type ALL_PROVISIONED_ACCOUNTS \
    --query 'PermissionSetProvisioningStatus.RequestId' --output text)"
  wait_for "provisioning ${4##*/}" describe-permission-set-provisioning-status --instance-arn "$2" \
    --provision-permission-set-request-id "${request}" --query 'PermissionSetProvisioningStatus.Status'
}

sync_group() {  # sync_group <name> <description>
  local name="$1" description="$2" id now out
  id="$(group_id "${name}")"
  echo "  Group  ${name}"
  if [[ -z "${id}" ]]; then
    CHANGES=$((CHANGES + 1))
    echo "    create group"
    [[ "${PHASE}" == apply ]] || return 0
    if ! out="$(ids create-group --identity-store-id "${IDENTITY_STORE}" --display-name "${name}" \
         ${description:+--description "${description}"} --query GroupId --output text 2>&1)"; then
      die "creating group ${name}: ${out}
       If IAM Identity Center takes its users and groups from an external identity provider
       (Okta, Entra ID, Google Workspace…), groups come from there: create ${name} in it, let
       it sync, and run this again."
    fi
    printf '%s\t%s\n' "${name}" "${out}" >> "${WORK}/group_ids"   # for the assignments
    return 0
  fi
  local before="${CHANGES}" was
  was="$(group_now "${name}")"
  if [[ "${was}" != "${name}" ]]; then
    change "rename ${was} to ${name}  (its members and assignments stay)" ids update-group \
      --identity-store-id "${IDENTITY_STORE}" --group-id "${id}" --operations "$(attribute displayName "${name}")"
  fi
  now="$(ids describe-group --identity-store-id "${IDENTITY_STORE}" --group-id "${id}" \
    --query Description --output text)"
  [[ "${now}" == "None" ]] && now=""
  if [[ -n "${description}" && "${now}" != "${description}" ]]; then
    change "update description" ids update-group --identity-store-id "${IDENTITY_STORE}" --group-id "${id}" \
      --operations "$(attribute description "${description}")"
  fi
  # Everyone in a former group is added, so taking it over takes no one's access away
  local have from fid user
  have="$(member_ids "${id}")"
  while IFS=$'\t' read -r -u 5 _ fid from; do
    while read -r -u 6 user; do
      grep -qxF "${user}" <<<"${have}" && continue
      have+=$'\n'"${user}"
      change "add $(ids describe-user --identity-store-id "${IDENTITY_STORE}" --user-id "${user}" \
          --query UserName --output text)  (from ${from}, which stays as it is)" \
        ids create-group-membership --identity-store-id "${IDENTITY_STORE}" --group-id "${id}" \
          --member-id "UserId=${user}"
    done 6< <(member_ids "${fid}")
  done 5< <(awk -F'\t' -v g="${name}" '$1 == g' "${WORK}/merge_from")
  (( CHANGES > before )) || echo "    up to date"
}
attribute() {  # attribute <path> <value>: an Identity Store update operation
  python3 -c 'import json, sys; print(json.dumps([{"AttributePath": sys.argv[1], "AttributeValue": sys.argv[2]}]))' "$1" "$2"
}

assign() {  # assign <group ID> <account ID> <permission set ARN>; waits for it to finish
  local request
  request="$(sso create-account-assignment --instance-arn "${INSTANCE}" \
    --principal-type GROUP --principal-id "$1" --target-type AWS_ACCOUNT --target-id "$2" \
    --permission-set-arn "$3" --query 'AccountAssignmentCreationStatus.RequestId' --output text)" || return 1
  wait_for "assigning ${3##*/} in $2" describe-account-assignment-creation-status --instance-arn "${INSTANCE}" \
    --account-assignment-creation-request-id "${request}" --query 'AccountAssignmentCreationStatus.Status'
}

sync_assignments() {  # sync_assignments <group>: its assignments, then the ones only AWS has
  local group="$1" gid arn account label ps
  gid="$(group_id "${group}")"
  echo "  ${group}"
  while IFS=$'\t' read -r -u 4 _ account label ps; do
    arn="$(existing_arn "${ps}")"
    if [[ -n "${gid}" && -n "${arn}" ]] && grep -qxF "${group}"$'\t'"${account}"$'\t'"${arn}" "${WORK}/current"; then
      echo "    ok      ${ps} in ${label}"
    elif [[ -z "${gid}" || -z "${arn}" ]] && [[ "${PHASE}" == plan ]]; then
      CHANGES=$((CHANGES + 1))
      echo "    assign ${ps} in ${label}  (after it is created)"
    else
      change "assign ${ps} in ${label}" assign "${gid}" "${account}" "${arn}"
    fi
  done 4< <(awk -F'\t' -v g="${group}" '$1 == g' "${WORK}/resolved")
  [[ "${PHASE}" == plan ]] || return 0

  # Report only: assignments this group has that its file does not list.
  while IFS=$'\t' read -r _ account arn; do
    ps="$(existing_name "${arn}")"
    if ! awk -F'\t' -v g="${group}" -v a="${account}" -v p="${ps}" \
         '$1 == g && $2 == a && $4 == p { f = 1 } END { exit !f }' "${WORK}/resolved"; then
      echo "    not in groups/${group}.json, left as is: ${ps:-${arn##*/}} in $(account_label "${account}")"
    fi
  done < <(awk -F'\t' -v g="${group}" '$1 == g' "${WORK}/current")
}

run_phase() {
  local name duration inline managed description
  # fd 3, so nothing inside a loop can read the work file as its stdin
  echo; echo "Permission sets"
  while IFS=$'\t' read -r -u 3 name duration inline managed description; do
    sync_set "${name}" "${duration}" "${inline}" "${managed}" "${description}"
  done 3< "${WORK}/definitions"

  echo; echo "Groups"
  while IFS=$'\t' read -r -u 3 name description; do
    sync_group "${name}" "${description}"
  done 3< "${WORK}/groups"

  echo; echo "Assignments"
  while IFS=$'\t' read -r -u 3 name _; do
    sync_assignments "${name}"
  done 3< "${WORK}/groups"
}

echo
echo "IAM Identity Center ${INSTANCE}"
echo "  account ${ACCOUNT_ID}${SSO_REGION:+, region ${SSO_REGION}}, identity store ${IDENTITY_STORE}"
run_phase

others="$(cut -f1 "${WORK}/existing" | grep -vxF -f <(cut -f1 "${WORK}/definitions") | tr '\n' ' ' || true)"
[[ -n "${others}" ]] && { echo; echo "  Permission sets not managed here, left as they are: ${others}"; }
if (( HAVE_CREDENTIALS )); then
  others="$(ids list-groups --identity-store-id "${IDENTITY_STORE}" --query 'Groups[].DisplayName' --output text |
    tr '\t' '\n' | grep -v '^None$' | grep -vxF -f <(cut -f1 "${WORK}/groups"; cut -f3 "${WORK}/group_ids"; echo '') | tr '\n' ' ' || true)"
  [[ -n "${others}" ]] && { echo; echo "  Groups not managed here, left as they are: ${others}"; }
fi

if (( DRY_RUN )); then
  while IFS=$'\t' read -r -u 3 _ _ inline _ _; do
    [[ "${inline}" == "-" ]] && continue
    echo; echo "── ${inline}"; cat "${DEFS_DIR}/${inline}"
    [[ -z "$(tail -c 1 "${DEFS_DIR}/${inline}")" ]] || echo   # a file without a final newline
    if (( HAVE_CREDENTIALS )); then
      findings="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
        --policy-document "file://${DEFS_DIR}/${inline}" \
        --query 'findings[].[findingType,issueCode]' --output text 2>&1 || true)"
      echo "   Access Analyzer: ${findings:-no findings}" | sed '2,$s/^/                    /'
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

PHASE=apply
CHANGES=0
run_phase
echo
echo "done. People are added to the groups in the console (IAM Identity Center > Groups)"
echo "or in your identity provider; nothing here removes anyone from a group."
