# shellcheck shell=bash
# Shared configuration for bootstrap-account.sh and check-policy.sh.
#
# Precedence: environment > answers to interactive prompts > config file
# (BOOTSTRAP_ENV, default ./bootstrap.env) > defaults. When stdin is a terminal,
# every question is asked, with the config file's value as its default, so each
# run confirms what it will use. Only the environment and arguments skip one.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${LIB_DIR}")"
CONFIG_FILE="${BOOTSTRAP_ENV:-${ROOT_DIR}/bootstrap.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # Only fill in what the environment has not already set, and remember each
  # value taken from the file (as CONFIG_FILE_<key>) so ask can confirm it.
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do   # a last line without a newline counts
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    value="${value%\"}"; value="${value#\"}"
    # A stray '=' or quote (often a curly one from a word processor) would become
    # part of a repository or role name.
    if [[ "${value}" == =* || "${value}" == *[\"\']* || "${value}" == *$'\xe2\x80\x9c'* || "${value}" == *$'\xe2\x80\x9d'* ]]; then
      echo "error: ${CONFIG_FILE}: ${key} is not KEY=\"value\" with plain double quotes: ${key}=${value}" >&2
      exit 1
    fi
    if [[ -z "${!key:-}" ]]; then
      export "${key}=${value}"
      printf -v "CONFIG_FILE_${key}" '%s' "${value}"
    fi
  done < "${CONFIG_FILE}"
fi

export OIDC_HOST="token.actions.githubusercontent.com"

render() { python3 "${LIB_DIR}/render.py" "$@"; }
die() { echo "error: $*" >&2; exit 1; }

# is_yes <value>: true for yes/y/true/1, false for no/n/false/0/empty, else an error.
is_yes() {
  case "$(tr '[:upper:]' '[:lower:]' <<<"$1")" in
    yes|y|true|1) return 0 ;;
    no|n|false|0|"") return 1 ;;
    *) die "expected yes or no, got '$1'" ;;
  esac
}

# --- Interactive prompts -------------------------------------------------------
INTERACTIVE=0; [[ -t 0 ]] && INTERACTIVE=1
ANSWERED=()   # variables set by a prompt, offered for saving afterwards

# ask <VAR> <question> [default] [optional]
# Prompts for VAR when the session is interactive, unless the environment or an
# argument already set it. A value from the config file is asked for too, as the
# default, so it is confirmed every run. A required value with no answer and no
# default is an error; an optional one may be blank, or '-' to clear a default.
ask() {
  local var="$1" question="$2" default="${3:-}" optional="${4:-}" answer
  local file_var="CONFIG_FILE_${var}" from_file=0
  [[ -n "${!file_var+set}" && "${!var-}" == "${!file_var}" ]] && from_file=1
  if (( from_file && INTERACTIVE )); then
    [[ -n "${!var}" ]] && default="${!var}"   # a blank in the file keeps the default
  elif [[ -n "${!var+set}" && ( -n "${!var}" || -n "${optional}" ) ]]; then
    return 0
  fi
  if (( ! INTERACTIVE )); then
    [[ -n "${default}" ]] && { export "${var}=${default}"; return 0; }
    [[ -n "${optional}" ]] && { export "${var}="; return 0; }
    die "${var} is not set (see bootstrap.env.example), and there is no terminal to ask"
  fi
  while :; do
    if [[ -n "${default}" && -n "${optional}" ]]; then
      read -r -p "${question} [${default}, - for none]: " answer
      answer="${answer:-${default}}"
      [[ "${answer}" == "-" ]] && answer=""
    elif [[ -n "${default}" ]]; then
      read -r -p "${question} [${default}]: " answer
      answer="${answer:-${default}}"
    else
      read -r -p "${question}: " answer
    fi
    [[ -n "${answer}" || -n "${optional}" ]] && break
    echo "  required"
  done
  export "${var}=${answer}"
  # Confirming the file's value changes nothing worth saving.
  (( from_file )) && [[ "${answer}" == "${!file_var}" ]] && return 0
  ANSWERED+=("${var}")
}

# Offer to write prompted answers to the config file, so the next run offers
# them as defaults. Never touches an existing file: it prints the lines instead.
offer_to_save() {
  (( ${#ANSWERED[@]} )) || return 0
  local lines=() var
  for var in "${ANSWERED[@]}"; do lines+=("${var}=\"${!var}\""); done
  echo
  if [[ -f "${CONFIG_FILE}" ]]; then
    echo "To make these the defaults next time, set in ${CONFIG_FILE}:"
    printf '  %s\n' "${lines[@]}"
    return 0
  fi
  local reply
  read -r -p "Save these answers to ${CONFIG_FILE}? [Y/n] " reply
  [[ "${reply}" == [nN]* ]] && return 0
  {
    echo "# Written by bootstrap-account.sh — see bootstrap.env.example for every option."
    printf '%s\n' "${lines[@]}"
  } > "${CONFIG_FILE}"
  echo "  saved"
}

# GitHub organisation of the repository you are standing in, if any — a default.
# Not this tool's own checkout: its remote is where the tool lives, not your org.
guess_github_org() {
  [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "${ROOT_DIR}" ]] && return 0
  git remote get-url origin 2>/dev/null |
    sed -nE 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)([^/]+)/.*#\2#p'
}

# --- Defaults, applied after any prompts ---------------------------------------
config_defaults() {
  export GITHUB_ORG="${GITHUB_ORG:-}"
  export ALLOWED_REGIONS="${ALLOWED_REGIONS:-us-east-1}"
  export STATE_BUCKETS="${STATE_BUCKETS:-}"

  # Platform: Terraform / Terragrunt. REPOS, ROLE_NAME and POLICY_NAME are the
  # pre-split names and still work.
  export PLATFORM_REPOS="${PLATFORM_REPOS:-${REPOS:-}}"
  export PLATFORM_ROLE_NAME="${PLATFORM_ROLE_NAME:-${ROLE_NAME:-platform-deploy-role}}"
  export PLATFORM_POLICY_NAME="${PLATFORM_POLICY_NAME:-${POLICY_NAME:-platform-deploy-policy}}"

  # Apps: SAM / CloudFormation. Empty APP_REPOS skips both app roles.
  export APP_REPOS="${APP_REPOS:-}"
  export APP_ROLE_NAME="${APP_ROLE_NAME:-app-deploy-role}"
  export APP_POLICY_NAME="${APP_POLICY_NAME:-app-deploy-policy}"
  export APP_EXEC_ROLE_NAME="${APP_EXEC_ROLE_NAME:-app-cfn-exec-role}"
  export APP_EXEC_POLICY_NAME="${APP_EXEC_POLICY_NAME:-app-cfn-exec-policy}"

  export LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME-lambda-test-role}"   # set to "" to skip

  # Security group for VPC-attached functions. Whether an account gets one, and
  # in which VPC, is asked per account (SECURITY_GROUP, SECURITY_GROUP_VPC_ID).
  export SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-app-default-sg}"
  # Where the group's id and the VPC's subnets are published:
  # <prefix>/security_group_id and <prefix>/subnet_ids.
  export VPC_SSM_PREFIX="${VPC_SSM_PREFIX-/default/vpc}"   # set to "" to skip

  # Create each repository's environments and set their AWS_* variables (needs gh).
  export CONFIGURE_GITHUB="${CONFIGURE_GITHUB:-true}"

  # Where apply writes the filled-in root.hcl and workflows.
  export OUTPUTS_DIR="${OUTPUTS_DIR:-${ROOT_DIR}/outputs}"
}
