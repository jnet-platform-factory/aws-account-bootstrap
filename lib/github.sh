# shellcheck shell=bash
# The GitHub side of the bootstrap, for bootstrap-account.sh: the environment each
# repository deploys from, and the variables its workflows read.
#
# For every repository and environment a trust policy names, it
#   - creates the environment if it does not exist. Protection rules are never set
#     or changed: add reviewers and branch rules in the repository's settings;
#   - sets AWS_ACCOUNT_ID, AWS_REGION and the ARN of each role that repository may
#     assume in that environment. An existing AWS_DEPLOY_ROLE_ARN is replaced only
#     if the person running apply says so; other variables are never touched.
#
# Uses the gh CLI, which needs admin access to each repository. Skipped when gh is
# missing or signed out, when there is no real account to point at, or when
# CONFIGURE_GITHUB=false.

GITHUB_FAILURES=0
GITHUB_DEPLOY_ROLE_CHOICES=""   # "<repo>\t<env>\t<arn>" lines: AWS_DEPLOY_ROLE_ARN to replace

# Prints why the GitHub side cannot run; prints nothing when it can.
github_skip_reason() {
  if [[ "${CONFIGURE_GITHUB}" != true ]]; then
    echo "CONFIGURE_GITHUB=${CONFIGURE_GITHUB}"
  elif (( ! HAVE_CREDENTIALS )); then
    echo "no AWS credentials, so no account to point the variables at"
  elif ! command -v gh >/dev/null; then
    echo "the gh CLI is not installed"
  elif ! gh auth status >/dev/null 2>&1; then
    echo "gh is not signed in (gh auth login)"
  fi
}

in_list() { [[ " $2 " == *" $1 "* ]]; }   # in_list <word> <space-separated list>

# "<repo> <environment>" for every pair a trust policy names, once each, by repo.
github_targets() {
  local repos envs r e
  {
    read -r -a repos <<<"${PLATFORM_REPOS}"
    read -r -a envs <<<"${PLATFORM_ENVIRONMENTS}"
    for r in "${repos[@]}"; do for e in "${envs[@]}"; do echo "${r} ${e}"; done; done
    if (( WITH_APPS )); then
      read -r -a repos <<<"${APP_REPOS}"
      read -r -a envs <<<"${APP_ENVIRONMENTS}"
      for r in "${repos[@]}"; do for e in "${envs[@]}"; do echo "${r} ${e}"; done; done
    fi
  } | sort -u
}

# github_variables <repo> <environment>: the variables it should have, NAME<TAB>value.
github_variables() {
  local role="arn:aws:iam::${ACCOUNT_ID}:role" regions
  read -r -a regions <<<"${ALLOWED_REGIONS}"
  printf '%s\t%s\n' AWS_ACCOUNT_ID "${ACCOUNT_ID}" AWS_REGION "${regions[0]}"
  if in_list "$1" "${PLATFORM_REPOS}" && in_list "$2" "${PLATFORM_ENVIRONMENTS}"; then
    printf '%s\t%s\n' AWS_PLATFORM_ROLE_ARN "${role}/${PLATFORM_ROLE_NAME}"
  fi
  if (( WITH_APPS )) && in_list "$1" "${APP_REPOS}" && in_list "$2" "${APP_ENVIRONMENTS}"; then
    printf '%s\t%s\n' AWS_APP_ROLE_ARN "${role}/${APP_ROLE_NAME}" \
                      AWS_CFN_EXEC_ROLE_ARN "${role}/${APP_EXEC_ROLE_NAME}"
  fi
}

github_failed() {  # github_failed <message>
  echo "  WARNING: $1" >&2
  GITHUB_FAILURES=$((GITHUB_FAILURES + 1))
}

# github_deploy_role_question <repo> <environment> <current AWS_DEPLOY_ROLE_ARN>
# Older workflows assume whatever AWS_DEPLOY_ROLE_ARN names, so replacing it switches
# them to a new role on their next run. Only the person running apply decides that:
# asked before the confirmation, never in a dry run or an unattended one.
github_deploy_role_question() {
  local name value arns=() roles=() answer choice="" i current="${3##*/}"
  # Same role name in another account looks like no change; name the account.
  [[ "$3" != *":${ACCOUNT_ID}:"* ]] && current="${current} in account $(cut -d: -f5 <<<"$3")"
  while IFS=$'\t' read -r name value; do
    case "${name}" in
      AWS_PLATFORM_ROLE_ARN|AWS_APP_ROLE_ARN) arns+=("${value}"); roles+=("${value##*/}") ;;
    esac
  done < <(github_variables "$1" "$2")
  for (( i = 0; i < ${#arns[@]}; i++ )); do
    if [[ "$3" == "${arns[i]}" ]]; then
      printf '      %-22s = %s\n' AWS_DEPLOY_ROLE_ARN "$3"
      return 0
    fi
  done
  if (( ${DRY_RUN:-0} )); then
    printf '      %-22s   %s: apply asks whether to replace it\n' AWS_DEPLOY_ROLE_ARN "${current}"
    return 0
  fi
  if (( ! INTERACTIVE )); then
    printf '      %-22s   left as it is (%s): unattended runs never replace it\n' AWS_DEPLOY_ROLE_ARN "${current}"
    return 0
  fi
  if (( ${#arns[@]} == 1 )); then
    read -r -p "      AWS_DEPLOY_ROLE_ARN is ${current}. Replace it with ${roles[0]}? [y/N] " answer
    [[ "${answer}" == [yY]* ]] && choice=0
  else
    read -r -p "      AWS_DEPLOY_ROLE_ARN is ${current}. Replace it with 1) ${roles[0]}, 2) ${roles[1]}, or keep it? [1/2/N] " answer
    case "${answer}" in 1) choice=0 ;; 2) choice=1 ;; esac
  fi
  if [[ -n "${choice}" ]]; then
    GITHUB_DEPLOY_ROLE_CHOICES+="$1"$'\t'"$2"$'\t'"${arns[choice]}"$'\n'
    printf '      %-22s ~ %s → %s\n' AWS_DEPLOY_ROLE_ARN "$3" "${arns[choice]}"
  else
    printf '      %-22s   left as it is (%s)\n' AWS_DEPLOY_ROLE_ARN "${current}"
  fi
}

# github_sync plan|apply — print what would change, or change it.
github_sync() {
  local mode="$1" reason repo env slug last="" info full admin rules exists current
  local name want have set_names set_values i
  echo
  echo " GitHub"
  reason="$(github_skip_reason)"
  if [[ -n "${reason}" ]]; then
    echo "  skipped: ${reason}"
    return 0
  fi

  # fd 3, so nothing inside the loop can swallow the list from stdin.
  while read -r repo env <&3; do
    slug="${GITHUB_ORG}/${repo}"
    if [[ "${repo}" != "${last}" ]]; then
      last="${repo}"
      [[ "${mode}" == plan ]] && echo "  ${slug}"
      if ! info="$(gh api "repos/${slug}" --jq '[.full_name, .permissions.admin] | @tsv' 2>/dev/null)"; then
        github_failed "${slug}: repository not found, or not visible to gh"
        admin=missing
        continue
      fi
      read -r full admin <<<"${info}"
      if [[ "${full}" != "${slug}" ]]; then
        # IAM compares the OIDC subject case-sensitively, and GitHub sends its own spelling.
        github_failed "${slug}: GitHub spells it ${full}, so its tokens will not match the trust policy; fix GITHUB_ORG or the repository name"
      fi
      if [[ "${admin}" != true ]]; then
        github_failed "${slug}: gh has no admin access, which environments and their variables need"
      fi
    fi
    [[ "${admin}" == true ]] || continue

    exists=0; rules=""
    if rules="$(gh api "repos/${slug}/environments/${env}" \
                  --jq '[.protection_rules[].type] | join(", ")' 2>/dev/null)"; then
      exists=1
    fi
    current=""
    if (( exists )) && ! current="$(gh api --paginate "repos/${slug}/environments/${env}/variables" \
                                      --jq '.variables[] | [.name, .value] | @tsv')"; then
      github_failed "${slug} (${env}): could not read the environment's variables"
      continue
    fi

    if [[ "${mode}" == plan ]]; then
      if (( ! exists )); then
        echo "    environment ${env}  CREATE, without protection rules"
      elif [[ -z "${rules}" ]]; then
        echo "    environment ${env}  exists, no protection rules: any branch can deploy"
      else
        echo "    environment ${env}  exists, protected by ${rules}"
      fi
    fi

    set_names=(); set_values=()
    while IFS=$'\t' read -r name want; do
      have="$(awk -F'\t' -v n="${name}" '$1 == n { print $2 }' <<<"${current}")"
      if [[ "${mode}" == plan ]]; then
        if [[ "${have}" == "${want}" ]]; then
          printf '      %-22s = %s\n' "${name}" "${want}"
        elif [[ -z "${have}" ]]; then
          printf '      %-22s + %s\n' "${name}" "${want}"
        else
          printf '      %-22s ~ %s → %s\n' "${name}" "${have}" "${want}"
          if [[ "${name}" == AWS_ACCOUNT_ID ]]; then
            echo "      WARNING: ${env} deploys to account ${have} today; apply points it at ${want} instead"
          fi
        fi
      elif [[ "${have}" != "${want}" ]]; then
        set_names+=("${name}"); set_values+=("${want}")
      fi
    done < <(github_variables "${repo}" "${env}")

    if [[ "${mode}" == plan ]]; then
      have="$(awk -F'\t' '$1 == "AWS_DEPLOY_ROLE_ARN" { print $2 }' <<<"${current}")"
      if [[ -n "${have}" ]]; then
        github_deploy_role_question "${repo}" "${env}" "${have}"
      fi
      continue
    fi

    # --- apply ---
    want="$(awk -F'\t' -v r="${repo}" -v e="${env}" '$1 == r && $2 == e { print $3 }' \
              <<<"${GITHUB_DEPLOY_ROLE_CHOICES}")"
    if [[ -n "${want}" ]]; then
      set_names+=(AWS_DEPLOY_ROLE_ARN); set_values+=("${want}")
    fi
    if (( ! exists )); then
      if ! gh api -X PUT "repos/${slug}/environments/${env}" --silent </dev/null; then
        github_failed "${slug} (${env}): could not create the environment"
        continue
      fi
    fi
    for (( i = 0; i < ${#set_names[@]}; i++ )); do
      if ! gh variable set "${set_names[i]}" --repo "${slug}" --env "${env}" \
             --body "${set_values[i]}" </dev/null; then
        github_failed "${slug} (${env}): could not set ${set_names[i]}"
      fi
    done
    if (( ! exists )); then
      echo "  ${slug} (${env}): environment created, set ${set_names[*]}"
    elif (( ${#set_names[@]} )); then
      echo "  ${slug} (${env}): set ${set_names[*]}"
    else
      echo "  ${slug} (${env}): up to date"
    fi
  done 3< <(github_targets)
}
