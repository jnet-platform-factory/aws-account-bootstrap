# aws-account-bootstrap

Keyless, scoped deploy roles for an AWS account — one for your **platform**
(Terraform), one for your **applications** (SAM / CloudFormation) — created by the one
script that has to exist before either tool can run.

```bash
make plan  PROFILE=dev           # asks for anything it needs, then shows what would change
make apply PROFILE=dev ENV=dev   # create / update the roles
make check PROFILE=dev           # read-only policy checks
```

The first run asks for your GitHub organisation, repositories, environments and
regions, and offers to save the answers to `bootstrap.env`; after that it only needs
the environments. `PROFILE` is an aws-vault profile — leave it out to use the
credentials you already have.

## What it creates

In the account your credentials belong to. Nothing else — no VPC, no security group,
no bucket, no function.

```
                          ┌─────────────────────────────┐
 GitHub Actions ──OIDC──► │ platform-deploy-role        │──► VPCs, databases, DNS, CDNs …   (Terraform)
 (PLATFORM_REPOS)         └─────────────────────────────┘

                          ┌─────────────────────────────┐  passes   ┌─────────────────────┐
 GitHub Actions ──OIDC──► │ app-deploy-role             │─────────► │ app-cfn-exec-role   │──► functions, APIs,
 (APP_REPOS)              │ drives CloudFormation only  │           │ used by CFN only    │    queues, topics …
                          └─────────────────────────────┘           └─────────────────────┘
```

| Resource                    | Name (default)                        | Assumed by                                              | Permissions                                                                                                                                          |
| --------------------------- | ------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| OIDC identity provider      | `token.actions.githubusercontent.com` | —                                                       | Lets GitHub Actions authenticate without access keys                                                                                                 |
| **Platform** role           | `platform-deploy-role`                | GitHub OIDC: `PLATFORM_REPOS` in the named environments | `platform-deploy-policy` — the services your Terraform manages                                                                                       |
| **App deploy** role         | `app-deploy-role`                     | GitHub OIDC: `APP_REPOS` in the named environments      | `app-deploy-policy` — drive CloudFormation stacks, upload SAM artifacts, pass the execution role. **Cannot create a function, role or queue itself** |
| **App execution** role      | `app-cfn-exec-role`                   | `cloudformation.amazonaws.com`, this account only       | `app-cfn-exec-policy` — the resources your application templates declare                                                                             |
| Test Lambda role (optional) | `lambda-test-role`                    | `lambda.amazonaws.com`, this account only               | `AWSLambdaBasicExecutionRole` — write logs, nothing else                                                                                             |

The app roles are skipped when `APP_REPOS` is empty, the test role when
`LAMBDA_ROLE_NAME` is empty. Everything is tagged `ManagedBy=aws-account-bootstrap`.

**Each deploy role ends up with exactly one managed policy.** If a role already exists
with `AdministratorAccess`, `PowerUserAccess` or anything else attached, the plan lists
each as `DETACH`; they are removed after the scoped policy is attached, so the role is
never left with nothing. Any one of them left in place would silently re-grant what the
scoped policy leaves out. Inline policies are reported, never deleted.

It is safe to re-run: existing resources are kept, trust policies are rewritten, and a
permissions policy gets a new default version only if its rendered JSON changed.
Re-running is how you add a repository or an environment — see
[Re-running](#re-running-adding-a-repository-or-an-environment).

### Why two roles for applications

With `sam deploy --role-arn`, CloudFormation creates the stack's resources as the
execution role, and the CI credentials only ever call CloudFormation. So a leaked CI
token can submit a stack — visible in the stack's event history, reviewable, rollable
back — but cannot call `lambda:UpdateFunctionCode` or `iam:CreateRole` directly. It is
the same split AWS CDK's bootstrap makes between its deploy and execution roles.

It only works if every deploy passes the role. Set it once per project:

```toml
# samconfig.toml
[default.deploy.parameters]
role_arn = "arn:aws:iam::<ACCOUNT_ID>:role/app-cfn-exec-role"
```

A deploy without it fails, because CloudFormation then acts as `app-deploy-role`,
which has no service permissions. That failure is the control working.

### Why platform and apps are separate

They change different things at different rates, through different reviews. The
platform role can create VPCs, databases and IAM roles but not deploy a function; the
app roles can deploy functions but not touch a VPC or a database. And a guardrail on
**every** role denies changes to any role or policy this bootstrap owns, so Terraform
cannot widen the app roles, an application stack cannot widen the platform role, and
nothing can widen itself.

### What it does not create, and why

- **Security groups.** A security group belongs to a VPC, and your VPCs are created by
  Terraform, after this runs. A test Lambda outside a VPC needs none.
- **Application roles.** The roles your functions run as come from your SAM templates —
  `app-cfn-exec-role` creates them per stack. `lambda-test-role` is for experiments only.
- **The Terraform state backend.** See [Terraform state](#terraform-state).

## The access model

Each account is reached **directly**: there is no hub role fanning out into the other
accounts, and the AWS Organizations management account is never in the path.

- **CI** exchanges its GitHub OIDC token for a deploy role. The trust policy accepts a
  token only when its subject is `repo:<org>/<repo>:environment:<env>` for a listed repo
  and environment, so **the GitHub environment's protection rules — required reviewers,
  branch restrictions — are what gate a deploy.** A job without `environment:` gets a
  branch-based subject and is refused.
- **Humans** use their own SSO session in the account. Nothing is assumed on top of it.

### Why not a hub account

A hub (one role in a tooling account, trusted by a deploy role in every other account)
makes a single role able to deploy everywhere. Lose it and you lose the estate. Direct
access caps a leaked credential at one account.

The **management account** must never be the hub. Service Control Policies do not apply
to it, so nothing can restrain a role that lives there, and it already holds
`OrganizationAccountAccessRole` into every member account. Keep it for Organizations,
IAM Identity Center and billing. If you do need a hub — many accounts, one CI identity —
put it in a dedicated deployment account.

## Usage

| Command                                  | What it does                                                                                                         |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `make plan [ENV=…] [PROFILE=…]`          | Prints the plan and every rendered policy. Changes nothing. Works without credentials, against a placeholder account |
| `make apply [ENV=…] [PROFILE=…] [YES=1]` | Creates or updates the roles. Asks for confirmation unless `YES=1`                                                   |
| `make check [PROFILE=…]`                 | Access Analyzer and IAM simulator checks. Read-only                                                                  |
| `make setup`                             | Copies `bootstrap.env.example` to `bootstrap.env`, if you prefer editing to answering                                |
| `make lint` / `make test`                | shellcheck and JSON checks / plus two dry runs, no AWS needed                                                        |
| `make`                                   | Help                                                                                                                 |

`CONFIG=path` points every target at another config file — one per organisation, for
example. The scripts run directly too: `./bootstrap-account.sh --help`.

**Anything missing is asked for** when you run interactively, with a sensible default
where there is one (your organisation is guessed from the git remote of the directory
you run it in). Answers can be saved to the config file; environments are never saved,
because they differ per account. With `--yes` (`YES=1`), or with no terminal — CI —
nothing is asked, and a missing required value is an error.

### A first run

`make plan` asks for what it is missing, prints the plan, and offers to save the
answers. The environment it asks for is a GitHub environment name — the one in each
repository's _Settings → Environments_ and in the workflow's `environment:` — not an
account ID.

```
$ make plan PROFILE=dev
Bootstrapping account 123456789012 (my-org-dev). A few questions first (Ctrl-C to stop).

GitHub organisation (or user) that owns the repositories: my-org
Repositories that run Terraform (space-separated, without the org): infrastructure
Repositories that deploy SAM / CloudFormation apps (blank: no app roles): api-service worker-service
GitHub environment(s) that may run Terraform in account 123456789012: dev
GitHub environment(s) that may deploy apps in account 123456789012 [dev]:
Region(s) the roles may act in [us-east-1]:

Account 123456789012 (my-org-dev)
  OIDC provider  token.actions.githubusercontent.com

 Platform
  IAM role       platform-deploy-role
                 assumed by 1 repo(s) in my-org, environment(s): dev
                 policy platform-deploy-policy (2595 / 6144 characters)

 Apps
  IAM role       app-deploy-role
                 assumed by 2 repo(s) in my-org, environment(s): dev
                 policy app-deploy-policy (3744 / 6144 characters)
  IAM role       app-cfn-exec-role
                 assumed by cloudformation.amazonaws.com in this account, when passed by app-deploy-role
                 policy app-cfn-exec-policy (3615 / 6144 characters)

 Test
  IAM role       lambda-test-role  AWSLambdaBasicExecutionRole, assumable by Lambda in this account

── app-exec-permissions.json
…                                     every rendered policy and trust document follows

Save these answers to ./bootstrap.env? [Y/n] y
  saved
```

From then on only the environment is needed. `apply` shows the same plan, without the
documents, and asks before changing anything:

```
$ make apply PROFILE=dev ENV=dev
…                                     the plan, as above
Proceed? [y/N] y

  OIDC provider: created
  platform-deploy-policy: created
  platform-deploy-role: created
  app-cfn-exec-policy: created
  app-cfn-exec-role: created
  app-deploy-policy: created
  app-deploy-role: created
  lambda-test-role: created

Done:
  arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com
  arn:aws:iam::123456789012:role/platform-deploy-role
  arn:aws:iam::123456789012:role/app-deploy-role
  arn:aws:iam::123456789012:role/app-cfn-exec-role
  arn:aws:iam::123456789012:role/lambda-test-role
```

### Re-running: adding a repository or an environment

Edit `bootstrap.env` and run `apply` again. Here `billing-service` was added to
`APP_REPOS`:

```
$ make apply PROFILE=dev ENV=dev
…
 Apps
  IAM role       app-deploy-role
                 assumed by 3 repo(s) in my-org, environment(s): dev
…
Proceed? [y/N] y

  OIDC provider: exists
  platform-deploy-policy: up to date
  platform-deploy-role: exists, trust policy rewritten
  app-cfn-exec-policy: up to date
  app-cfn-exec-role: exists, trust policy rewritten
  app-deploy-policy: up to date
  app-deploy-role: exists, trust policy rewritten
  lambda-test-role: exists, trust policy rewritten
```

Only the trust policies changed; the permissions policies were compared and left alone.
A role's trust policy is always rewritten, even when the result is identical, and a
permissions policy prints `new default version` only when its JSON actually changed.

- **The lists replace, they do not add.** Each trust policy is rebuilt from the current
  `PLATFORM_REPOS` / `APP_REPOS` and environments. Give the full list every time: a run
  with only the new repository locks out all the others.
- **Change `bootstrap.env`, not the prompt.** A value in the config file is never asked
  for again, and the script never rewrites an existing config file — it prints the
  lines to add instead. For one run, an environment variable wins over the file:
  `APP_REPOS="api-service worker-service billing-service" make plan PROFILE=dev ENV=dev`.
- **Pass the environments every run.** They are never saved, because they differ per
  account. To allow several, list them all: `ENV="dev preview"`.
- **Run `make plan` first.** It prints the exact trust policy, so you can check the
  `repo:<org>/<repo>:environment:<env>` subjects before anything changes.
- **Spell `GITHUB_ORG` the way GitHub does.** IAM compares the OIDC subject
  case-sensitively, and GitHub writes the organisation as its canonical login, so
  `My-Org` does not match a token for `my-org`. Check with
  `gh api orgs/<org> --jq .login` (or `users/<name>` for a personal account).

Re-running only ever creates or updates. It does not converge in these cases:

- **Emptying `APP_REPOS`** skips the app roles; existing ones are left in place with their
  old trust policy. Delete them by hand if they should go.
- **Renaming** a role or policy creates a new one and leaves the old one behind,
  unprotected by the guardrails.
- **Descriptions, tags and session duration** of an existing role are left as they were.

## Configuration

Set these in `bootstrap.env` (answer the prompts and save, run `make setup`, or copy
[`bootstrap.env.example`](bootstrap.env.example); it is git-ignored) or in the
environment, which wins.

| Variable                                      | Default                            | Meaning                                                               |
| --------------------------------------------- | ---------------------------------- | --------------------------------------------------------------------- |
| `GITHUB_ORG`                                  | — (required)                       | Organisation or user that owns the repositories                       |
| `PLATFORM_REPOS`                              | — (required)                       | Repositories that may assume the platform role                        |
| `PLATFORM_ENVIRONMENTS`                       | the script's arguments             | GitHub environments for the platform role                             |
| `APP_REPOS`                                   | empty                              | Repositories that may assume the app deploy role. Empty: no app roles |
| `APP_ENVIRONMENTS`                            | the script's arguments             | GitHub environments for the app deploy role                           |
| `ALLOWED_REGIONS`                             | `us-east-1`                        | Regions every role may act in; global services are exempt             |
| `STATE_BUCKETS`                               | empty                              | State buckets no role may delete, re-policy or un-version             |
| `PLATFORM_ROLE_NAME` / `PLATFORM_POLICY_NAME` | `platform-deploy-role` / `-policy` |                                                                       |
| `APP_ROLE_NAME` / `APP_POLICY_NAME`           | `app-deploy-role` / `-policy`      |                                                                       |
| `APP_EXEC_ROLE_NAME` / `APP_EXEC_POLICY_NAME` | `app-cfn-exec-role` / `-policy`    |                                                                       |
| `LAMBDA_ROLE_NAME`                            | `lambda-test-role`                 | Set to `""` to skip                                                   |
| `BOOTSTRAP_ENV`                               | `./bootstrap.env`                  | Alternative config file                                               |

`REPOS`, `ROLE_NAME` and `POLICY_NAME` from earlier versions still work as the platform
values.

The script's arguments are the GitHub environments that may deploy into **this**
account, for both roles unless overridden:

```bash
./bootstrap-account.sh dev
./bootstrap-account.sh staging production
APP_ENVIRONMENTS="dev preview" ./bootstrap-account.sh dev     # apps also deploy previews
```

**Reusable workflows:** list the _calling_ repositories. The OIDC subject names the
repository the run belongs to, not the one the reusable workflow lives in.

**Trust policy size.** IAM caps a trust policy at 2048 characters by default (the
_Role trust policy length_ quota, adjustable to 4096). Each repo × environment pair is
one subject, so roughly 13 repos × 2 environments is the limit. The plan warns.

**Names.** Choose them before the first run. The guardrails are rendered with them, so
a rename leaves the old resources unprotected and unmanaged.

## The policies

Templates live in [`policies/`](policies/) and are rendered by
[`lib/render.py`](lib/render.py) with `{{ACCOUNT_ID}}`, `{{ALLOWED_REGIONS}}` and the
names above. `--dry-run` prints every rendered document.

### Guardrails — on every role ([`guardrails.json`](policies/guardrails.json))

| Statement                   | Effect                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------- |
| `DenyOutsideAllowedRegions` | **Deny** every regional call outside `ALLOWED_REGIONS`                                |
| `DenyTouchingTheBootstrap`  | **Deny** changes to every role and policy listed above, and the OIDC provider         |
| `DenyLongLivedCredentials`  | **Deny** access keys and console passwords                                            |
| `DenyBreakingStateBuckets`  | **Deny** deleting, re-policying or un-versioning `STATE_BUCKETS` (omitted when empty) |

Denies hold whatever else is ever attached to a role.

### Platform ([`platform-deploy-policy.json`](policies/platform-deploy-policy.json))

| Statement                          | Effect                                                                                                      |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `ServicesTerraformManages`         | `<service>:*` for each service your Terraform manages                                                       |
| `ApiGatewayVpcLinksOnly`           | API Gateway, limited to VPC links — an example of scoping a service to the one resource type Terraform owns |
| `IamExceptPassRole`                | IAM read and write, without `PassRole`                                                                      |
| `PassRoleToConfiguredServices`     | `iam:PassRole` only to the listed services                                                                  |
| `ReadOnlyLookups`                  | `organizations:DescribeOrganization`, `sts:GetCallerIdentity`                                               |
| `DenyUnexpectedServiceLinkedRoles` | **Deny** service-linked roles except for the listed services                                                |

The default service list fits an estate built from VPCs, RDS, DynamoDB, S3, CloudFront,
Cognito, Route 53, ACM, SES, SNS, Secrets Manager, SSM, KMS, ECR, OpenSearch, AppConfig
and AWS Config. Lambda, EventBridge and SQS are deliberately absent: they are the app
roles' job.

### App deploy ([`app-deploy-policy.json`](policies/app-deploy-policy.json))

| Statement                   | Effect                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------- |
| `DriveStacks`               | Create, update, delete and roll back stacks and change sets in this account           |
| `UseTransforms`             | Use AWS-owned transforms such as `AWS::Serverless-2016-10-31`                         |
| `AccountLevelReads`         | Template validation, stack listing, ECR login                                         |
| `PassOnlyTheExecutionRole`  | `iam:PassRole` for `app-cfn-exec-role`, and only to CloudFormation                    |
| `SamArtifactBucket`         | The `aws-sam-cli-managed-default-*` bucket `resolve_s3 = true` creates and uploads to |
| `PushFunctionImages`        | Push container images for `PackageType: Image` functions                              |
| `ResolveTemplateParameters` | Read SSM parameters referenced by `AWS::SSM::Parameter::Value` template parameters    |
| `PostDeploySteps`           | Invoke functions and read their logs — smoke tests, migration runners                 |

### App execution ([`app-cfn-exec-policy.json`](policies/app-cfn-exec-policy.json))

| Statement                           | Effect                                                                                                                                                            |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ServicesAppsUse`                   | `<service>:*` for Lambda, API Gateway, Logs, CloudWatch, SQS, SNS, EventBridge, Scheduler, Firehose, DynamoDB, S3, SES                                            |
| `Parameters`                        | Create and update SSM parameters                                                                                                                                  |
| `DnsRecordsOnly`                    | Route 53 **records**, not zones                                                                                                                                   |
| `Reads`                             | Certificates for custom domains, VPC lookups for VPC-attached functions, secrets for `{{resolve:secretsmanager:…}}`, KMS for encrypted resources, ECR image pulls |
| `FunctionRoles`                     | Create and manage the roles SAM generates for each function                                                                                                       |
| `PassRoleToAppServices`             | `iam:PassRole` only to Lambda, API Gateway, EventBridge, Scheduler, Firehose                                                                                      |
| `ServiceLinkedRoles`                | Only API Gateway's                                                                                                                                                |
| `DenyAttachingBroadManagedPolicies` | **Deny** attaching `AdministratorAccess`, `PowerUserAccess` or `IAMFullAccess` to any role                                                                        |

### Tailoring the service lists

The defaults are a starting point. Edit them to match what your code actually declares:

1. **Terraform** — list the resource types your code and its downloaded modules use:

   ```bash
   grep -rhoE '^\s*(resource|data)\s+"aws_[a-z0-9_]+"' --include='*.tf' . \
     | sed -E 's/^\s*//; s/"//g' | sort | uniq -c
   ```

2. **SAM / CloudFormation** — list the resource types in your templates:

   ```bash
   find . -name 'template.y*ml' -not -path '*/.aws-sam/*' -not -path '*/node_modules/*' \
     -exec grep -hoE 'Type: *AWS::[A-Za-z0-9]+::[A-Za-z0-9]+' {} + | sort | uniq -c | sort -rn
   ```

   and check for features that need extra permissions: `VpcConfig` (EC2 lookups),
   `PackageType: Image` (ECR), `{{resolve:secretsmanager` (secret reads), KMS keys,
   custom domains (ACM).

3. **Compare with what the current roles have actually used** — IAM records the last
   use of each service over 400 days:

   ```bash
   job=$(aws iam generate-service-last-accessed-details \
           --arn arn:aws:iam::<ACCOUNT_ID>:role/<CURRENT_ROLE> --query JobId --output text)
   aws iam get-service-last-accessed-details --job-id "$job" \
     --query 'ServicesLastAccessed[?LastAuthenticated!=`null`].[ServiceNamespace,LastAuthenticated]' \
     --output text
   ```

4. **Update the `PassRole` and service-linked-role lists** for any service you add.

5. **Run `./check-policy.sh`**, then re-run the bootstrap in each account.

Service-level wildcards (`rds:*`) are deliberate. An action-by-action list sounds tighter
but breaks in practice: refreshing or updating one resource calls read APIs nobody
writes down. The reduction comes from the services that are absent and from the denies.

### What it does not protect against

Both the platform role and the app execution role can create IAM roles, because
Terraform and SAM both have to. A determined misuse could create a role with broad
inline permissions and use it. The fix is a **permissions boundary** that every created
role must carry — for SAM, `PermissionsBoundary` in each template's `Globals.Function`,
and a condition on `iam:CreateRole` requiring `iam:PermissionsBoundary` in the
execution policy. That means adding the boundary everywhere first, so this repository
does not impose it.

### When a deploy hits `AccessDenied`

Something new needs a permission. Add it to the right template, run `./check-policy.sh`,
and re-run the bootstrap; the previous four versions of each policy are kept:

```bash
aws iam list-policy-versions --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/<POLICY_NAME>
aws iam set-default-policy-version --policy-arn … --version-id v<N>      # roll back
```

For a SAM deploy, the stack's events name the resource and the action; the failing
principal tells you which role to change — `app-deploy-role` for upload and change-set
errors, `app-cfn-exec-role` for resource creation.

## Checking the policies

```bash
aws-vault exec dev -- ./check-policy.sh
```

Read-only. For every role it renders the policy with your configuration, runs
**Access Analyzer** `validate-policy` (failing on `ERROR` or `SECURITY_WARNING`), and
runs the **IAM policy simulator** on cases that must be allowed or denied: the
guardrails on every role; regions, `PassRole` and service-linked roles for the
platform; for the app deploy role, that it can drive stacks and pass only the execution
role but cannot create a function or role itself; for the execution role, that it can
create functions and their roles but cannot attach `AdministratorAccess`, delete a
hosted zone, or launch instances.

`CREATE_SLR_WITH_STAR_IN_ACTION_AND_RESOURCE` on the platform policy is expected — the
analyzer does not evaluate deny statements. The simulator accepts at most 2000
characters per document, so each policy is split into chunks first.

## Using the roles from GitHub Actions

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev # required — the trust policy matches on it
    permissions:
      id-token: write # lets the job request an OIDC token
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/app-deploy-role # or platform-deploy-role
          aws-region: us-east-1
      - run: sam build && sam deploy --no-confirm-changeset # role_arn comes from samconfig.toml
```

Before adding an environment to an account's trust policy, review its protection rules:
anyone who can run a job in that environment, in any listed repository, gets that role
in that account.

## Terraform state

This repository does not create a state backend, and with Terraform 1.10+ you no longer
need a DynamoDB lock table: `use_lockfile = true` in the S3 backend writes the lock next
to the state object.

If state lives in a **different account** from the one being deployed, the platform role
reaches it cross-account, so the bucket policy must allow it.
[`policies/state-bucket-policy.json`](policies/state-bucket-policy.json) is the template:
one copy per account, scoped to that account's keys.

- **Scope by key pattern, not one prefix.** If repositories lay out keys differently
  (`<app>/<env>/<component>/` in one, `<service>/<component>/<env>/` in another), "this
  account's state" is a list of patterns. S3 ARNs and the `s3:prefix` condition accept
  `*` anywhere, e.g. `*/dev/*` — but `*` also matches across `/`, so check each pattern
  against the bucket's real keys and make sure no production key matches a
  non-production pattern.
- **`put-bucket-policy` replaces the whole document.** Fetch the current policy, add the
  new statements, write the merged result back.
- **Know where your backend came from.** Terragrunt used to create a missing state bucket
  and lock table on the first `init`, with whatever credentials it held — which is how
  backends end up in unexpected accounts and outside any Terraform code. Current
  Terragrunt does that only with `--backend-bootstrap`. Never pass it in CI.

## Migrating from shared or broad roles

1. Run the bootstrap in one account. **It replaces each deploy role's trust policy** —
   if a role of the same name is already in use through a hub or access keys, that path
   stops working. New role names avoid that and let old and new run side by side.
2. Platform: point Terraform at the new role (remove the hub `assume_role` / Terragrunt
   `iam_role`, keep `allowed_account_ids`), grant its state keys, switch to
   `use_lockfile`.
3. Apps: add `role_arn` to each `samconfig.toml`, and point CI at `app-deploy-role`.
4. CI: add `id-token: write`, remove the access keys, run every job in a GitHub
   environment.
5. Deploy once per component and stack — expect no changes. An `AccessDenied` is a gap
   in a service list.
6. Repeat per account. Delete the old roles, and the access keys behind them, after the
   last one.

If a Terragrunt root config is shared by every environment, switch per environment (a
list of environments already on direct access, checked against the one parsed from the
path), or migrating one account moves them all.

## Requirements

- AWS CLI v2, and IAM admin in the target account
- `python3` (standard library only)
- `bash` 3.2 or later — the macOS system bash works

## License

[Apache-2.0](LICENSE)
