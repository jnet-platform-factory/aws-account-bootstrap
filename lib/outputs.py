#!/usr/bin/env python3
"""Write copy-paste-ready files for the repositories that deploy with the roles.

Every apply records the account it ran in, one file per GitHub environment, under
OUTPUTS_DIR/accounts/. The files rendered from those records cover every account
applied so far, so a dev run followed by a production run gives one root.hcl that
switches between the two.

Usage:
  outputs.py record            record this run's account (configuration from the environment)
  outputs.py render [DIR]      render OUTPUTS_DIR's records into DIR (default OUTPUTS_DIR)
  outputs.py sample DIR        render two made-up accounts into DIR: the repository's examples/

Recorded from the environment: ACCOUNT_ID, ACCOUNT_ALIAS, GITHUB_ORG, PLATFORM_REPOS,
APP_REPOS, PLATFORM_ENVIRONMENTS, APP_ENVIRONMENTS, ALLOWED_REGIONS, the role names,
and the local profile: BOOTSTRAP_PROFILE, else AWS_VAULT, else AWS_PROFILE, else the
environment's own name.
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "templates"


def env(name, default=""):
    return os.environ.get(name, "") or default


def outputs_dir():
    return Path(env("OUTPUTS_DIR", str(ROOT / "outputs")))


def record():
    account, org = env("ACCOUNT_ID"), env("GITHUB_ORG")
    if not account or not org:
        sys.exit("outputs.py: ACCOUNT_ID and GITHUB_ORG must be set")
    platform_envs = env("PLATFORM_ENVIRONMENTS").split()
    app_envs = env("APP_ENVIRONMENTS").split() if env("APP_REPOS") else []
    role = f"arn:aws:iam::{account}:role"
    directory = outputs_dir() / "accounts"
    directory.mkdir(parents=True, exist_ok=True)
    for name in dict.fromkeys(platform_envs + app_envs):  # in order, once each
        entry = {
            "environment": name,
            "account_id": account,
            "account_alias": env("ACCOUNT_ALIAS"),
            "region": env("ALLOWED_REGIONS", "us-east-1").split()[0],
            "profile": env("BOOTSTRAP_PROFILE") or env("AWS_VAULT") or env("AWS_PROFILE") or name,
            "github_org": org,
            "state_bucket": f"{org.lower()}-tfstate-{account}",
        }
        if name in platform_envs:
            entry["platform_repos"] = env("PLATFORM_REPOS").split()
            entry["platform_role_arn"] = f"{role}/{env('PLATFORM_ROLE_NAME', 'platform-deploy-role')}"
        if name in app_envs:
            entry["app_repos"] = env("APP_REPOS").split()
            entry["app_role_arn"] = f"{role}/{env('APP_ROLE_NAME', 'app-deploy-role')}"
            entry["cfn_exec_role_arn"] = f"{role}/{env('APP_EXEC_ROLE_NAME', 'app-cfn-exec-role')}"
        (directory / f"{name}.json").write_text(json.dumps(entry, indent=2) + "\n")


def load_records():
    directory = outputs_dir() / "accounts"
    records = [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]
    if not records:
        sys.exit(f"outputs.py: nothing recorded in {directory} yet; run make apply first")
    return records


def sample_records():
    """Two made-up accounts, for the examples/ shown in the repository."""
    out = []
    for name, account in (("dev", "111111111111"), ("production", "222222222222")):
        role = f"arn:aws:iam::{account}:role"
        out.append({
            "environment": name, "account_id": account, "account_alias": f"my-org-{name}",
            "region": "us-east-1", "profile": name, "github_org": "my-org",
            "state_bucket": f"my-org-tfstate-{account}",
            "platform_repos": ["infrastructure"],
            "platform_role_arn": f"{role}/platform-deploy-role",
            "app_repos": ["api-service", "worker-service"],
            "app_role_arn": f"{role}/app-deploy-role",
            "cfn_exec_role_arn": f"{role}/app-cfn-exec-role",
        })
    return out


def ordered(records):
    """dev first (the default for pull requests and pushes), then by name."""
    return sorted(records, key=lambda r: (r["environment"] != "dev", r["environment"]))


def fill(template, values):
    """Replace {{NAME}}; GitHub's own ${{ expr }} has spaces and is left alone."""
    text = (TEMPLATES / template).read_text()

    def lookup(match):
        if match.group(1) not in values:
            sys.exit(f"outputs.py: {template} has no value for {{{{{match.group(1)}}}}}")
        return values[match.group(1)]

    return re.sub(r"\{\{([A-Z_]+)\}\}", lookup, text)


def union(records, key):
    return " ".join(dict.fromkeys(repo for r in records for repo in r.get(key, [])))


def role_name(records, key):
    return records[0][key].rsplit("/", 1)[1] if records else ""


def render(records, target):
    records = ordered(records)
    platform = [r for r in records if "platform_role_arn" in r]
    apps = [r for r in records if "app_role_arn" in r]
    files = []

    if platform:
        width = max(len(r["environment"]) for r in platform)
        accounts = "\n".join(
            f'    {r["environment"]:<{width}} = {{ account_id = "{r["account_id"]}", region = "{r["region"]}", '
            f'profile = "{r["profile"]}", state_bucket = "{r["state_bucket"]}" }}'
            for r in platform)
        common = {
            "GITHUB_ORG": platform[0]["github_org"],
            "PLATFORM_ROLE_NAME": role_name(platform, "platform_role_arn"),
            "PLATFORM_REPOS": union(platform, "platform_repos"),
            "FIRST_ENV": platform[0]["environment"],
            "FIRST_ACCOUNT_ID": platform[0]["account_id"],
            "PLATFORM_ENV_LIST": ", ".join(r["environment"] for r in platform),
            "PLATFORM_ENV_OPTIONS": "\n".join(f"          - {r['environment']}" for r in platform),
            "ACCOUNTS": accounts,
        }
        write(target / "terragrunt/live/root.hcl", fill("root.hcl", common))
        write(target / "github-actions/terragrunt.yml", fill("terragrunt.yml", common))
        files += [
            ("terragrunt/live/root.hcl", "`infrastructure/live/root.hcl` in " + list_repos(common["PLATFORM_REPOS"])),
            ("github-actions/terragrunt.yml", "`.github/workflows/` in the same repositories"),
        ]

    if apps:
        values = {
            "GITHUB_ORG": apps[0]["github_org"],
            "APP_ROLE_NAME": role_name(apps, "app_role_arn"),
            "APP_REPOS": union(apps, "app_repos"),
            "FIRST_APP_ENV": apps[0]["environment"],
            "APP_ENV_LIST": ", ".join(r["environment"] for r in apps),
            "APP_ENV_OPTIONS": "\n".join(f"          - {r['environment']}" for r in apps),
        }
        write(target / "github-actions/sam-deploy.yml", fill("sam-deploy.yml", values))
        files.append(("github-actions/sam-deploy.yml",
                      "`.github/workflows/` in " + list_repos(values["APP_REPOS"])))

    rows = ["| Environment | Account | Region | Local profile | Roles |",
            "| ----------- | ------- | ------ | ------------- | ----- |"]
    for r in records:
        roles = [r[k].rsplit("/", 1)[1] for k in ("platform_role_arn", "app_role_arn") if k in r]
        account = r["account_id"] + (f" ({r['account_alias']})" if r.get("account_alias") else "")
        rows.append(f"| `{r['environment']}` | {account} | {r['region']} | `{r['profile']}` | "
                    + ", ".join(f"`{x}`" for x in roles) + " |")
    readme = fill("README.md", {
        "GITHUB_ORG": records[0]["github_org"],
        "ACCOUNTS_TABLE": "\n".join(rows),
        "FILES": "\n".join(f"- [`{path}`]({path}) → {where}" for path, where in files),
        "STATE_BUCKETS": " ".join(dict.fromkeys(r["state_bucket"] for r in platform)),
    })
    write(target / "README.md", readme)


def list_repos(repos):
    return ", ".join(f"`{r}`" for r in repos.split())


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def main(argv):
    command = argv[0] if argv else ""
    if command == "record":
        record()
    elif command == "render":
        target = Path(argv[1]) if len(argv) > 1 else outputs_dir()
        render(load_records(), target)
        print(f"  {target}/README.md")
    elif command == "sample" and len(argv) > 1:
        render(sample_records(), Path(argv[1]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
