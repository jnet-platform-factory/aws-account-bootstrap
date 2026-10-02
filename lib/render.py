#!/usr/bin/env python3
"""Render the IAM policy documents the bootstrap scripts apply or check.

Configuration comes from environment variables, which lib/config.sh sets:

  ACCOUNT_ID                         12-digit account the documents are for
  GITHUB_ORG                         GitHub organisation (or user) owning the repos
  PLATFORM_REPOS, APP_REPOS          space-separated repository names, without the org
  PLATFORM_ENVIRONMENTS, APP_ENVIRONMENTS
                                     space-separated GitHub environment names
  ALLOWED_REGIONS                    space-separated regions; everything else is denied
  STATE_BUCKETS                      space-separated state bucket names (optional)
  PLATFORM_ROLE_NAME, PLATFORM_POLICY_NAME
  APP_ROLE_NAME, APP_POLICY_NAME, APP_EXEC_ROLE_NAME, APP_EXEC_POLICY_NAME
  LAMBDA_ROLE_NAME                   resource names (an empty name is skipped)

Usage:
  render.py permissions ROLE     ROLE's permissions policy, guardrails included
  render.py trust ROLE           ROLE's GitHub OIDC trust policy (platform | app)
  render.py service-trust SVC    trust policy for an AWS service (lambda | cloudformation)
  render.py sim-input ROLE       ROLE's permissions split for the IAM policy simulator
  render.py canonical FILE       FILE (or -) with sorted keys, for comparison

ROLE is platform, app or app-exec.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

POLICIES = Path(__file__).resolve().parent.parent / "policies"
TEMPLATES = {
    "platform": "platform-deploy-policy.json",
    "app": "app-deploy-policy.json",
    "app-exec": "app-cfn-exec-policy.json",
}
OIDC_HOST = "token.actions.githubusercontent.com"
SIMULATOR_LIMIT = 2000  # characters per document, enforced by iam:SimulateCustomPolicy


def env(name):
    return os.environ.get(name, "")


def env_list(name):
    return env(name).split()


def require(name):
    if not env(name):
        sys.exit(f"render.py: {name} is not set")
    return env(name)


def substitute(node, scalars, lists):
    """A string that is exactly "{{LIST}}" becomes that list; "{{SCALAR}}" is
    replaced inside any string. Anything left unresolved is an error."""
    if isinstance(node, dict):
        return {k: substitute(v, scalars, lists) for k, v in node.items()}
    if isinstance(node, list):
        return [substitute(v, scalars, lists) for v in node]
    if isinstance(node, str):
        for name, values in lists.items():
            if node == "{{" + name + "}}":
                return values
        for name, value in scalars.items():
            node = node.replace("{{" + name + "}}", value)
        if "{{" in node:
            sys.exit(f"render.py: unresolved placeholder in {node!r}")
    return node


def bootstrap_arns():
    """Everything the bootstrap owns. No deploy role may change any of it — so
    Terraform cannot widen the app roles, and nothing can widen itself."""
    roles = ["PLATFORM_ROLE_NAME", "APP_ROLE_NAME", "APP_EXEC_ROLE_NAME", "LAMBDA_ROLE_NAME"]
    policies = ["PLATFORM_POLICY_NAME", "APP_POLICY_NAME", "APP_EXEC_POLICY_NAME"]
    arns = [f"arn:aws:iam::*:role/{env(r)}" for r in roles if env(r)]
    arns += [f"arn:aws:iam::*:policy/{env(p)}" for p in policies if env(p)]
    arns.append(f"arn:aws:iam::*:oidc-provider/{OIDC_HOST}")
    return arns


def permissions(role):
    if role not in TEMPLATES:
        sys.exit(f"render.py: unknown role {role!r}")
    doc = json.loads((POLICIES / TEMPLATES[role]).read_text())
    guardrails = json.loads((POLICIES / "guardrails.json").read_text())["Statement"]
    if not env_list("STATE_BUCKETS"):
        # Nothing to protect: drop the statement rather than deny on an empty list.
        guardrails = [s for s in guardrails if s.get("Sid") != "DenyBreakingStateBuckets"]
    doc["Statement"] += guardrails
    regions = env_list("ALLOWED_REGIONS")
    if not regions:
        sys.exit("render.py: ALLOWED_REGIONS is empty")
    return substitute(
        doc,
        scalars={
            "ACCOUNT_ID": require("ACCOUNT_ID"),
            "APP_EXEC_ROLE_NAME": env("APP_EXEC_ROLE_NAME") or "app-cfn-exec-role",
        },
        lists={
            "ALLOWED_REGIONS": regions,
            "BOOTSTRAP_ARNS": bootstrap_arns(),
            "STATE_BUCKET_ARNS": [f"arn:aws:s3:::{b}" for b in env_list("STATE_BUCKETS")],
        },
    )


def subject_prefixes(org, repo):
    """Every `sub` prefix GitHub may put in this repository's tokens.

    With immutable subject claims on, GitHub sends
    `repo:<org>@<org id>/<repo>@<repo id>:...` instead of `repo:<org>/<repo>:...`,
    and a trust policy naming only the second refuses every token with a bare
    "Not authorized to perform sts:AssumeRoleWithWebIdentity". The ids cannot be
    derived from the names, so they are looked up. Without gh, or for a
    repository gh cannot see, only the name form is trusted — which is what the
    trust policy said before this lookup existed.
    """
    prefixes = [f"repo:{org}/{repo}"]
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{org}/{repo}/actions/oidc/customization/sub"],
            capture_output=True, text=True, timeout=20, check=True,
        ).stdout
        setting = json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return prefixes
    immutable = setting.get("sub_claim_prefix", "")
    if setting.get("use_immutable_subject") and immutable and immutable not in prefixes:
        prefixes.append(immutable)
    return prefixes


def trust(role):
    prefix = {"platform": "PLATFORM", "app": "APP"}.get(role)
    if not prefix:
        sys.exit(f"render.py: only platform and app are assumed via GitHub, not {role!r}")
    account, org = require("ACCOUNT_ID"), require("GITHUB_ORG")
    repos, envs = env_list(f"{prefix}_REPOS"), env_list(f"{prefix}_ENVIRONMENTS")
    if not repos or not envs:
        sys.exit(f"render.py: {prefix}_REPOS and {prefix}_ENVIRONMENTS must both be non-empty")
    subjects = [f"{p}:environment:{e}" for r in repos for p in subject_prefixes(org, r) for e in envs]
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "GitHubActionsOIDC",
            "Effect": "Allow",
            "Principal": {"Federated": f"arn:aws:iam::{account}:oidc-provider/{OIDC_HOST}"},
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {"StringEquals": {
                f"{OIDC_HOST}:aud": "sts.amazonaws.com",
                f"{OIDC_HOST}:sub": subjects,
            }},
        }],
    }


def service_trust(service):
    if service not in ("lambda", "cloudformation"):
        sys.exit(f"render.py: unknown service {service!r}")
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "ServiceInThisAccount",
            "Effect": "Allow",
            "Principal": {"Service": f"{service}.amazonaws.com"},
            "Action": "sts:AssumeRole",
            # Stops the service acting for another account from being handed this role.
            "Condition": {"StringEquals": {"aws:SourceAccount": require("ACCOUNT_ID")}},
        }],
    }


def compact(doc):
    return json.dumps(doc, separators=(",", ":"))


def sim_input(role):
    """Split into documents the simulator accepts; it evaluates them together."""
    docs, chunk = [], []
    for statement in permissions(role)["Statement"]:
        if chunk and len(compact({"Version": "2012-10-17", "Statement": chunk + [statement]})) > SIMULATOR_LIMIT:
            docs.append(compact({"Version": "2012-10-17", "Statement": chunk}))
            chunk = []
        chunk.append(statement)
    docs.append(compact({"Version": "2012-10-17", "Statement": chunk}))
    return docs


def main(argv):
    if len(argv) < 2 and argv[:1] != ["canonical"]:
        sys.exit(__doc__)
    command, arg = argv[0], (argv[1] if len(argv) > 1 else "-")
    if command == "permissions":
        print(json.dumps(permissions(arg), indent=2))
    elif command == "trust":
        print(json.dumps(trust(arg), indent=2))
    elif command == "service-trust":
        print(json.dumps(service_trust(arg), indent=2))
    elif command == "sim-input":
        print(json.dumps(sim_input(arg)))
    elif command == "canonical":
        source = sys.stdin if arg == "-" else open(arg)
        print(json.dumps(json.load(source), sort_keys=True, separators=(",", ":")))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
