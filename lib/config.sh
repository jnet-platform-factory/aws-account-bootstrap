# shellcheck shell=bash
# Shared configuration for bootstrap-account.sh and check-policy.sh.
#
# Precedence: environment > config file (BOOTSTRAP_ENV, default ./bootstrap.env)
# > answers to interactive prompts > defaults. Prompts only appear when a
# required value is still missing and stdin is a terminal.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${LIB_DIR}")"
CONFIG_FILE="${BOOTSTRAP_ENV:-${ROOT_DIR}/bootstrap.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # Only fill in what the environment has not already set.
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    value="${value%\"}"; value="${value#\"}"
    [[ -z "${!key:-}" ]] && export "${key}=${value}"
  done < "${CONFIG_FILE}"
fi

export OIDC_HOST="token.actions.githubusercontent.com"

render() { python3 "${LIB_DIR}/render.py" "$@"; }
die() { echo "error: $*" >&2; exit 1; }

# --- Interactive prompts -------------------------------------------------------
INTERACTIVE=0; [[ -t 0 ]] && INTERACTIVE=1
ANSWERED=()   # variables set by a prompt, offered for saving afterwards

# ask <VAR> <question> [default] [optional]
# Prompts for VAR when it is unset and the session is interactive. A required
# value with no answer and no default is an error; an optional one may be blank.
ask() {
  local var="$1" question="$2" default="${3:-}" optional="${4:-}" answer
  [[ -n "${!var+set}" && ( -n "${!var}" || -n "${optional}" ) ]] && return 0
  if (( ! INTERACTIVE )); then
    [[ -n "${default}" ]] && { export "${var}=${default}"; return 0; }
    [[ -n "${optional}" ]] && { export "${var}="; return 0; }
    die "${var} is not set (see bootstrap.env.example), and there is no terminal to ask"
  fi
  while :; do
    if [[ -n "${default}" ]]; then
      read -r -p "${question} [${default}]: " answer
      answer="${answer:-${default}}"
    else
      read -r -p "${question}: " answer
    fi
    [[ -n "${answer}" || -n "${optional}" ]] && break
    echo "  required"
  done
  export "${var}=${answer}"
  ANSWERED+=("${var}")
}

# Offer to write prompted answers to the config file, so the next run asks nothing.
# Never touches an existing file: it prints the lines to add instead.
offer_to_save() {
  (( ${#ANSWERED[@]} )) || return 0
  local lines=() var
  for var in "${ANSWERED[@]}"; do lines+=("${var}=\"${!var}\""); done
  echo
  if [[ -f "${CONFIG_FILE}" ]]; then
    echo "To skip these questions next time, add to ${CONFIG_FILE}:"
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

  # Create each repository's environments and set their AWS_* variables (needs gh).
  export CONFIGURE_GITHUB="${CONFIGURE_GITHUB:-true}"

  # Where apply writes the filled-in root.hcl and workflows.
  export OUTPUTS_DIR="${OUTPUTS_DIR:-${ROOT_DIR}/outputs}"
}
