#!/usr/bin/env bash
# Read-only check of every deploy policy, rendered with your configuration,
# against IAM Access Analyzer and the IAM policy simulator. Changes nothing.
# Run it after every edit to policies/:
#
#   ./check-policy.sh
#
# Exits non-zero if Access Analyzer reports an error or a security warning, or if
# any simulated decision differs from what the policy is meant to do.
#
# The guardrail cases hold for any configuration. The service cases (rds allowed
# for the platform, lambda denied to it, and so on) reflect the default templates:
# change them when you change a template's service list.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(dirname "$0")/lib/config.sh"
config_defaults

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS credentials"
export ACCOUNT_ID
WITH_APPS=0; [[ -n "${APP_REPOS}" ]] && WITH_APPS=1

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
roles=(platform); (( WITH_APPS )) && roles+=(app app-exec)
for r in "${roles[@]}"; do
  render permissions "${r}" > "${WORK}/${r}.json"
  render sim-input   "${r}" > "${WORK}/${r}.sim.json"
done

failures=0

echo "== Access Analyzer"
for r in "${roles[@]}"; do
  findings="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
    --policy-document "file://${WORK}/${r}.json" \
    --query 'findings[].[findingType,issueCode]' --output text)"
  if [[ -z "${findings}" ]]; then
    echo "  ${r}: no findings"
    continue
  fi
  while IFS= read -r line; do echo "  ${r}: ${line}"; done <<<"${findings}"
  # The analyzer does not evaluate denies, so it cannot see that
  # DenyUnexpectedServiceLinkedRoles answers this one.
  if grep -q CREATE_SLR_WITH_STAR_IN_ACTION_AND_RESOURCE <<<"${findings}"; then
    echo "  ${r}: (CREATE_SLR_WITH_STAR_IN_ACTION_AND_RESOURCE is covered by DenyUnexpectedServiceLinkedRoles)"
  fi
  if grep -qE '^(ERROR|SECURITY_WARNING)' <<<"${findings}"; then failures=$((failures + 1)); fi
done

ctx() { echo "ContextKeyName=$1,ContextKeyType=string,ContextKeyValues=$2"; }
expect() {  # expect <role> <decision> <action> [resource-arn] [context-entry]
  local role="$1" want="$2" action="$3" resource="${4:-}" context="${5:-}" got mark
  local args=(--policy-input-list "file://${WORK}/${role}.sim.json" --action-names "${action}")
  [[ -n "${resource}" ]] && args+=(--resource-arns "${resource}")
  [[ -n "${context}" ]] && args+=(--context-entries "${context}")
  got="$(aws iam simulate-custom-policy "${args[@]}" --query 'EvaluationResults[0].EvalDecision' --output text)"
  if [[ "${got}" == "${want}" ]]; then mark=ok; else mark=FAIL; failures=$((failures + 1)); fi
  printf "  %-4s %-9s %-13s %-36s %s\n" "${mark}" "${role}" "${got}" "${action}" "${resource##*:}"
}

read -r -a regions <<<"${ALLOWED_REGIONS}"
here="$(ctx aws:RequestedRegion "${regions[0]}")"
elsewhere=""
for candidate in ap-southeast-2 eu-west-1 sa-east-1; do
  [[ " ${ALLOWED_REGIONS} " == *" ${candidate} "* ]] || { elsewhere="$(ctx aws:RequestedRegion "${candidate}")"; break; }
done
ROLE="arn:aws:iam::${ACCOUNT_ID}:role"
passed_to() { ctx iam:PassedToService "$1"; }

echo "== Guardrails (every role)"
for r in "${roles[@]}"; do
  expect "${r}" explicitDeny iam:CreateAccessKey
  expect "${r}" explicitDeny iam:AttachRolePolicy "${ROLE}/${PLATFORM_ROLE_NAME}"
  (( WITH_APPS )) && expect "${r}" explicitDeny iam:PutRolePolicy "${ROLE}/${APP_EXEC_ROLE_NAME}"
  for bucket in ${STATE_BUCKETS}; do
    expect "${r}" explicitDeny s3:DeleteBucket "arn:aws:s3:::${bucket}" "${here}"
  done
done
expect platform explicitDeny rds:CreateDBInstance "" "${elsewhere}"

echo "== Platform"
expect platform allowed      rds:CreateDBInstance        "" "${here}"
expect platform implicitDeny lambda:CreateFunction       "" "${here}"
expect platform allowed      iam:CreateRole
expect platform allowed      iam:AttachRolePolicy        "${ROLE}/some-service-role"
expect platform allowed      iam:PassRole                "${ROLE}/x" "$(passed_to rds.amazonaws.com)"
expect platform implicitDeny iam:PassRole                "${ROLE}/x" "$(passed_to lambda.amazonaws.com)"
expect platform allowed      iam:CreateServiceLinkedRole "" "$(ctx iam:AWSServiceName rds.amazonaws.com)"
expect platform explicitDeny iam:CreateServiceLinkedRole "" "$(ctx iam:AWSServiceName lambda.amazonaws.com)"
expect platform allowed      route53:ChangeResourceRecordSets
expect platform implicitDeny organizations:LeaveOrganization

if (( WITH_APPS )); then
  STACK="arn:aws:cloudformation:${regions[0]}:${ACCOUNT_ID}:stack/my-api-dev/x"
  SAM_BUCKET="arn:aws:s3:::aws-sam-cli-managed-default-samclisourcebucket-abc123"
  echo "== App deploy (CI)"
  expect app allowed      cloudformation:CreateChangeSet  "${STACK}" "${here}"
  expect app allowed      cloudformation:ExecuteChangeSet "${STACK}" "${here}"
  expect app allowed      iam:PassRole        "${ROLE}/${APP_EXEC_ROLE_NAME}" "$(passed_to cloudformation.amazonaws.com)"
  expect app implicitDeny iam:PassRole        "${ROLE}/${PLATFORM_ROLE_NAME}" "$(passed_to cloudformation.amazonaws.com)"
  expect app implicitDeny iam:PassRole        "${ROLE}/${APP_EXEC_ROLE_NAME}" "$(passed_to lambda.amazonaws.com)"
  expect app allowed      s3:PutObject        "${SAM_BUCKET}/my-api/abc.zip" "${here}"
  expect app implicitDeny s3:PutObject        "arn:aws:s3:::someone-elses-bucket/x" "${here}"
  expect app implicitDeny lambda:CreateFunction "" "${here}"
  expect app implicitDeny lambda:UpdateFunctionCode "arn:aws:lambda:${regions[0]}:${ACCOUNT_ID}:function:my-fn" "${here}"
  expect app allowed      lambda:InvokeFunction "arn:aws:lambda:${regions[0]}:${ACCOUNT_ID}:function:my-fn" "${here}"
  expect app implicitDeny iam:CreateRole
  expect app explicitDeny cloudformation:CreateChangeSet "${STACK}" "${elsewhere}"
  # A post-deploy e2e run reads its stack's API key value - and nothing else
  # in API Gateway, and never writes it.
  expect app allowed      apigateway:GET      "arn:aws:apigateway:${regions[0]}::/apikeys/abc123" "${here}"
  expect app implicitDeny apigateway:GET      "arn:aws:apigateway:${regions[0]}::/restapis/abc123" "${here}"
  expect app implicitDeny apigateway:DELETE   "arn:aws:apigateway:${regions[0]}::/apikeys/abc123" "${here}"

  echo "== App execution (CloudFormation)"
  expect app-exec allowed      lambda:CreateFunction  "" "${here}"
  expect app-exec allowed      sqs:CreateQueue        "" "${here}"
  expect app-exec allowed      iam:CreateRole         "${ROLE}/my-api-dev-FunctionRole-ABC"
  expect app-exec allowed      iam:PassRole           "${ROLE}/my-api-dev-FunctionRole-ABC" "$(passed_to lambda.amazonaws.com)"
  expect app-exec implicitDeny iam:PassRole           "${ROLE}/x" "$(passed_to ec2.amazonaws.com)"
  expect app-exec explicitDeny iam:AttachRolePolicy   "${ROLE}/my-api-dev-FunctionRole-ABC" \
                               "$(ctx iam:PolicyARN arn:aws:iam::aws:policy/AdministratorAccess)"
  expect app-exec allowed      iam:AttachRolePolicy   "${ROLE}/my-api-dev-FunctionRole-ABC" \
                               "$(ctx iam:PolicyARN arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole)"
  expect app-exec allowed      route53:ChangeResourceRecordSets
  expect app-exec implicitDeny route53:DeleteHostedZone
  expect app-exec implicitDeny rds:CreateDBInstance   "" "${here}"
  expect app-exec implicitDeny ec2:RunInstances       "" "${here}"
  expect app-exec allowed      ec2:DescribeSubnets    "" "${here}"
  # Not simulated: MacroTransforms (CreateChangeSet on aws:transform/*). The
  # simulator cannot evaluate a transform ARN - even Allow on "*" comes back
  # implicitDeny - so a case here would only ever report a false failure.
fi

echo
if (( failures )); then echo "${failures} problem(s)"; exit 1; fi
echo "all decisions as intended"
