# aws-account-bootstrap

Keyless, scoped deploy roles for an AWS account — one for your **platform**
(Terraform), one for your **applications** (SAM / CloudFormation) — created by the one
script that has to exist before either tool can run. It also creates each repository's
GitHub environments and sets the variables its workflows need to assume those roles,
and writes a Terragrunt `root.hcl` and GitHub Actions workflows, filled in for your
accounts, to copy into those repositories. And, in the organization's management
account, the IAM Identity Center permission sets people sign in with.

## Before you start: accounts and organizational units

The account is the boundary everything here relies on: a deploy role, a permission set
and a leaked credential each reach one account and no further. So the organization
needs **at least three accounts**, and dev and production are never the same one:

| Account        | Holds                                                        | Workloads   |
| -------------- | ------------------------------------------------------------ | ----------- |
| **Management** | AWS Organizations, IAM Identity Center, consolidated billing | None — ever |
| **dev**        | Everything developers build and break                        | Yes         |
| **production** | What customers use                                           | Yes         |

Staging, a shared-services or a network account are added the same way when you need
them; dev and production are the minimum. Each workload account is bootstrapped on its
own (step 2) and maps to the GitHub environment of the same name, so a `production`
deploy can only ever reach the production account.

Group the accounts in **organizational units**, so that a Service Control Policy is
attached once per kind of account rather than once per account:

```
Root
├── Management                  the management account alone — SCPs never apply to it
├── Security       (optional)   log archive, audit
├── Infrastructure (optional)   shared services, network
├── Sandbox        (optional)   experiments, no path to production
├── Suspended      (optional)   closed accounts awaiting deletion — deny-all SCP
└── Workloads
    ├── NonProd                 dev, staging
    └── Prod                    production
```

Every organization uses this same tree, with these same names. OUs are named for the
environment, never the product: an organization already belongs to one product, so an
`Acme` OU inside the Acme organization says nothing the organization doesn't,
and identical names let one set of SCPs, StackSet targets and monitoring templates
serve every organization. The product goes in the account name (`acme-prod`,
`acme-dev`) and the `Product` tag. If one organization ever hosts two products that need
different SCPs, nest the product under the environment — `Workloads/Prod/Payments` — never
above it; if their SCPs are the same, the tag is enough.

Keeping NonProd and Prod apart is what lets production get the stricter rules — an SCP
that pins regions or blocks deleting backups — without slowing dev down. The OU also
says who signs in where. IAM Identity Center assigns permission sets per account, not per
OU, so give a new account the same assignments as the others in its OU — a line in each
[group file](identity-center/groups/) that names one of them. The management account is
named by its OU, `Management`, because its name is whatever the organization was created
with:

| Group        | Dev                   | Production          | Management (OU)       |
| ------------ | --------------------- | ------------------- | --------------------- |
| `Developers` | `DeveloperFullAccess` | `DeveloperReadOnly` | —                     |
| `Platform`   | `PlatformOps`         | `PlatformOps`       | —                     |
| `Admins`     | —                     | —                   | `AdministratorAccess` |
| `Billing`    | —                     | —                   | `BillingManagement`   |

This repository creates neither accounts nor OUs nor SCPs. Make them once, in the
management account, in **AWS Organizations → AWS accounts**, or with the CLI:

```bash
ROOT=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
MANAGEMENT=$(aws organizations create-organizational-unit --parent-id "$ROOT" --name Management \
               --query 'OrganizationalUnit.Id' --output text)
aws organizations move-account --source-parent-id "$ROOT" --destination-parent-id "$MANAGEMENT" \
  --account-id "$(aws organizations describe-organization --query Organization.MasterAccountId --output text)"
WORKLOADS=$(aws organizations create-organizational-unit --parent-id "$ROOT" --name Workloads \
              --query 'OrganizationalUnit.Id' --output text)
NONPROD=$(aws organizations create-organizational-unit --parent-id "$WORKLOADS" --name NonProd \
            --query 'OrganizationalUnit.Id' --output text)
PROD=$(aws organizations create-organizational-unit --parent-id "$WORKLOADS" --name Prod \
         --query 'OrganizationalUnit.Id' --output text)

# A new account (its email must be unused by any other AWS account), then move it into its OU
aws organizations create-account --account-name dev --email aws-dev@example.com
aws organizations move-account --account-id 111111111111 --source-parent-id "$ROOT" \
  --destination-parent-id "$NONPROD"
```

`create-account` returns a request id; `aws organizations describe-create-account-status`
gives the account id once it is ready. An existing account is only moved.

Renaming an OU keeps its id and the SCPs attached to it. In an organization managed by
**Control Tower**, create, rename and move OUs and accounts in Control Tower instead — a
change made directly in Organizations shows up as drift, and the OU has to be
re-registered.

Then two steps, in this order:
Renaming an OU keeps its id and the SCPs attached to it. In an organization managed by
**Control Tower**, create, rename and move OUs and accounts in Control Tower instead — a
change made directly in Organizations shows up as drift, and the OU has to be
re-registered.


```bash
# 1. Once, in the management account: the permission sets, groups and assignments everyone signs in with
make sso-plan  PROFILE=management   # shows what would change
make sso-apply PROFILE=management   # create / update them

# 2. Then in each of the other accounts: the deploy roles
make plan  PROFILE=dev              # asks for anything it needs, then shows what would change
make apply PROFILE=dev ENV=dev      # create / update the roles and the GitHub environments
make check PROFILE=dev              # read-only policy checks
```

The first run asks for your GitHub organisation, repositories, environments and
regions, and offers to save the answers to `bootstrap.env`; every later run asks again,
with the saved answers as defaults, so Enter confirms each one. `PROFILE` is an aws-vault profile — leave it out to use the
credentials you already have.

## First: the management account

Do this once, before bootstrapping any other account in the organization. People reach
every account through IAM Identity Center, which lives in the management account, so the
permission sets they sign in with, the groups they belong to and which group gets which
permission set in which account have to exist before anyone works in the others. One
script, [`identity-center.sh`](identity-center.sh), creates all three from the files in
[`identity-center/`](identity-center/). The
management account gets no deploy roles — see [Why not a hub account](#why-not-a-hub-account) —
and everything after this section is about the other accounts.

There are five permission sets, defined in
[`identity-center/permission-sets.json`](identity-center/permission-sets.json):

| Permission set        | AWS managed policies               | Inline policy ([`identity-center/policies/`](identity-center/policies/))                                                                                                                                                                                               | Session |
| --------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `AdministratorAccess` | `AdministratorAccess`              | —                                                                                                                                                                                                                                                                      | 1 hour  |
| `PlatformOps`         | `PowerUserAccess`, `IAMFullAccess` | **Deny** access keys and console passwords, changes to the Identity Center and organization access roles, turning off security tooling, deleting backups or KMS keys, billing changes, long-term purchases                                                             | 8 hours |
| `DeveloperFullAccess` | `PowerUserAccess`                  | IAM read; `PassRole` for any role but the privileged ones; **deny** the privileged roles, networking changes, large instance / database / cache sizes, expensive services, Identity Center changes, turning off security tooling, billing changes, long-term purchases | 8 hours |
| `DeveloperReadOnly`   | `ReadOnlyAccess`                   | **Deny** reading secret values                                                                                                                                                                                                                                         | 8 hours |
| `BillingManagement`   | `job-function/Billing`             | Read-only view of the organization's accounts and OUs                                                                                                                                                                                                                  | 8 hours |

"Long-term purchases" are Savings Plans, reserved capacity (EC2, RDS, ElastiCache,
Redshift, OpenSearch, DynamoDB), Shield Advanced and Marketplace subscriptions — each
commits the company to a bill for a year or more. `AdministratorAccess` can still make
them.

`PlatformOps` is the platform team's role in dev and production alike: it is what Terraform runs as
from a laptop, and what `make apply` runs as, since `DeveloperFullAccess` can only read IAM. It is for
running production, networking included: VPCs, subnets,
routes, NAT and transit gateways, VPN, Direct Connect, DNS, and IAM. What it cannot do is
the irreversible or the out-of-band: create access keys or console passwords, change the
roles Identity Center and AWS Organizations sign in through, turn off the security tooling,
or delete backups — AWS Backup vaults and recovery points, RDS and DynamoDB snapshots and
backups — or schedule a KMS key for deletion. Those go through `AdministratorAccess`.

`DeveloperFullAccess` is for **dev accounts only**: every service, but nothing written in
IAM, and nothing that changes the network or runs up a large bill. The network is the
platform's — developers use the VPCs, subnets and DNS zones Terraform made, and can
create security groups, load balancers and DNS records in them, but cannot create or
change a VPC, subnet, route, NAT, internet or transit gateway, VPN, endpoint, network ACL,
peering, Elastic IP or hosted zone, nor use Direct Connect, Cloud WAN, Network Firewall,
Global Accelerator, VPC Lattice, Resolver rules or RAM sharing. Instances are limited to
`t3`/`t3a`/`t4g` and sizes up to `xlarge`, never GPU, accelerated or memory-optimised
families; databases to `db.t3`/`db.t4g`, Serverless or `*.large`; caches to `cache.t3`/
`cache.t4g` or `*.large`. EKS, EMR, MSK, Redshift, OpenSearch, MemoryDB, DocumentDB
Elastic, Neptune Analytics, FSx, Kendra, WorkSpaces, SageMaker endpoints, training and
notebooks, Bedrock provisioned throughput and fine-tuning, Lambda provisioned
concurrency, dedicated hosts and capacity reservations cannot be created. The size
limits apply to what a developer launches directly; an Auto Scaling group or ECS
capacity provider launches as its own service role, so a budget alert on the dev account
is still the backstop.

Developers can pass any existing role to the services they build on — a
function's execution role, an ECS task role, a SageMaker or EventBridge role; the services
are listed under `iam:PassedToService`, add one there if a deploy needs it — except the
privileged ones, which they can neither pass nor assume: `OrganizationAccountAccessRole`, the
Identity Center roles, `stacksets-exec-*`, `platform-deploy-role`, `app-deploy-role`, and
any role named `*terraform*`, `*Terraform*` or `cicd-*`. If your deploy roles have other
names, add them to [`DeveloperFullAccess.json`](identity-center/policies/DeveloperFullAccess.json).
Passing a role is using its permissions, so **a role with `AdministratorAccess` that a
service can assume makes every developer an administrator** — keep none.

New roles come from templates, never by hand. A SAM deploy from a laptop works the way CI
does: pass `--role-arn` for `app-cfn-exec-role` (or set `role_arn` in `samconfig.toml`)
and CloudFormation creates the function roles; without it, the deploy fails at the first
role. Console wizards that offer to "create a new role" fail the same way — pick an
existing one.

It also cannot create or change an IAM Identity Center instance, or stop or weaken CloudTrail,
GuardDuty, Security Hub, AWS Config or IAM Access Analyzer, or change billing, payment
methods or tax settings — Cost Explorer, budgets and invoices stay readable. "Long-term
purchases" here also include registering or transferring a domain.

### Groups and assignments

Each group is a file in [`identity-center/groups/`](identity-center/groups/), named after
the group, listing the permission set it gets in each account. An assignment names the
account by its name in AWS Organizations or its 12-digit ID (`"account"`), or by the OU it
sits in (`"ou"`): a path from the root, `Management` or `Workloads/Prod`, that must hold
exactly one active account. The OU is for an account whose name is not yours to choose,
like the management account (the `Admins` file below); `Developers` names its accounts:

```json
{
  "description": "Developers: full access in dev, read-only in production.",
  "assignments": [
    { "account": "Dev", "permissionSet": "DeveloperFullAccess" },
    { "account": "Production", "permissionSet": "DeveloperReadOnly" }
  ]
}
```

A new group is a new file; a new account is a line in each group that should reach it.
Every name is checked before anything is called: a permission set that is not in
`permission-sets.json`, an account name that matches no account (or more than one), an OU
that does not exist or does not hold exactly one active account, or a suspended account
stops the run.

A group that already exists under another name is taken over rather than duplicated: list
its older names in `"formerly"`. When the group does not exist yet, the former group with
the most members (the first listed, on a tie) is renamed in place, so its members and its
assignments stay. Everyone in the other former groups is added to it, so nobody loses
access; those groups are left as they are, to delete once nothing needs them. The plan
names each person it adds:

```json
{
  "description": "Account administrators and break-glass access.",
  "formerly": ["Administrators", "Admin"],
  "assignments": [
    { "ou": "Management", "permissionSet": "AdministratorAccess" }
  ]
}
```

A permission set cannot be renamed in AWS, so one that already exists is managed under its
existing name: give the definition that name, and its policies are brought in line and it is
re-provisioned wherever it is assigned.

**Who is in a group is not set here**, beyond what a takeover adds — add people in the console (**IAM Identity Center →
Groups**) or in your identity provider. If Identity Center takes its users and groups from
an external identity provider (Okta, Entra ID, Google Workspace), the groups come from it
too: create them there, let them sync, and the script finds them by name.

### Creating them

```bash
make sso-plan  PROFILE=management   # the plan, every inline policy, and Access Analyzer's findings
make sso-apply PROFILE=management   # create or update them; asks first unless YES=1
```

It works in three steps — permission sets, then groups, then assignments — and is safe to
re-run. Each permission set's description, session duration, managed policies and inline
policy are made to match the files, and a changed permission set is re-provisioned to
every account it is assigned in. A missing group is created and a missing assignment is
made. It never deletes a permission set or a group and **never removes an assignment**:
one that a group has in AWS but not in its file is listed in the plan and left alone, as
are permission sets and groups that are not in the files. IAM Identity Center is in one
region: set `SSO_REGION` if it is not your profile's.

Or paste them by hand. In the console, **IAM Identity Center → Permission sets → Create
permission set → Custom permission set**, attach the managed policies, and paste the
JSON file as the inline policy. With the CLI, for one permission set:

```bash
INSTANCE=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
PS=$(aws sso-admin create-permission-set --instance-arn "$INSTANCE" --name DeveloperFullAccess \
       --session-duration PT8H --description "Developers: every service except IAM, which is read-only." \
       --query 'PermissionSet.PermissionSetArn' --output text)
aws sso-admin attach-managed-policy-to-permission-set --instance-arn "$INSTANCE" --permission-set-arn "$PS" \
  --managed-policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws sso-admin put-inline-policy-to-permission-set --instance-arn "$INSTANCE" --permission-set-arn "$PS" \
  --inline-policy file://identity-center/policies/DeveloperFullAccess.json
```

Once the groups have their people, sign in to the next account and run step 2.

## What it creates

In the account your credentials belong to, and in the GitHub environments that deploy
to it — and, only if you answer yes, one security group. Nothing else — no VPC, no
subnet, no bucket, no function.

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

| Security group (optional) | `app-default-sg` | VPC-attached functions, via their `VpcConfig` | All egress, no ingress. Published to SSM with the VPC's subnets — see below |

The app roles are skipped when `APP_REPOS` is empty, the test role when
`LAMBDA_ROLE_NAME` is empty.

**The security group is asked for on every run**, per account, as the environments
are: whether to create one (`SECURITY_GROUP=yes`), and in which VPC
(`SECURITY_GROUP_VPC_ID`, default: the default VPC of the first allowed region). The
group is created with no ingress rule and the default allow-all egress rule, so it
restricts nothing. Two SSM parameters, in that region, are what a template's
`VpcConfig` reads:

| Parameter                        | Type         | Value                                       |
| -------------------------------- | ------------ | ------------------------------------------- |
| `/default/vpc/security_group_id` | `String`     | The group's id                              |
| `/default/vpc/subnet_ids`        | `StringList` | The VPC's private subnets, read on each run |

```yaml
SubnetIds:
  {
    Type: "AWS::SSM::Parameter::Value<List<String>>",
    Default: /default/vpc/subnet_ids,
  }
SecurityGroupId:
  {
    Type: "AWS::SSM::Parameter::Value<String>",
    Default: /default/vpc/security_group_id,
  }
```

**Private** means the subnet's route table has no route to an internet gateway. A VPC
with none — the default VPC — has all of its subnets published instead, and the plan
says so: those functions reach AWS services but not the internet.

Both are tagged `ManagedBy=aws-account-bootstrap` and kept current on re-runs — a
subnet added to the VPC is picked up next time. One that exists **without** that tag
was written by something else and is left alone, with a warning. `VPC_SSM_PREFIX`
changes the `/default/vpc` prefix. Everything is tagged `ManagedBy=aws-account-bootstrap`.

**Each deploy role ends up with exactly one managed policy.** If a role already exists
with `AdministratorAccess`, `PowerUserAccess` or anything else attached, the plan lists
each as `DETACH`; they are removed after the scoped policy is attached, so the role is
never left with nothing. Any one of them left in place would silently re-grant what the
scoped policy leaves out. Inline policies are reported, never deleted.

### In GitHub

For every repository and environment a trust policy names, the environment is created
if it does not exist, and these
[environment variables](https://docs.github.com/actions/learn-github-actions/variables)
are set:

| Variable                | Set in                                     | Value                                 |
| ----------------------- | ------------------------------------------ | ------------------------------------- |
| `AWS_ACCOUNT_ID`        | every environment                          | This account                          |
| `AWS_REGION`            | every environment                          | The first of `ALLOWED_REGIONS`        |
| `AWS_PLATFORM_ROLE_ARN` | `PLATFORM_REPOS` × `PLATFORM_ENVIRONMENTS` | `platform-deploy-role`                |
| `AWS_APP_ROLE_ARN`      | `APP_REPOS` × `APP_ENVIRONMENTS`           | `app-deploy-role`                     |
| `AWS_CFN_EXEC_ROLE_ARN` | `APP_REPOS` × `APP_ENVIRONMENTS`           | `app-cfn-exec-role`, for `--role-arn` |

A repository in both lists gets both role ARNs, so its Terraform and SAM jobs each
assume their own role. A workflow uses them like this:

```yaml
jobs:
  deploy:
    environment: dev # required: the trust policy matches on it
    permissions: { id-token: write, contents: read }
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_APP_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - run: sam deploy --role-arn "${{ vars.AWS_CFN_EXEC_ROLE_ARN }}" …
```

**Protection rules are never set or changed** — that is a decision per environment
(who approves a production deploy, which branches may), so make it in the repository's
_Settings → Environments_. The plan shows each environment's rules and flags the ones
that have none. Other variables are left alone, with one exception.

**An existing `AWS_DEPLOY_ROLE_ARN` is replaced only if you say so.** Workflows from
before this bootstrap often assume whatever that variable names, so replacing it moves
them onto the new role on their next run, with no change to the workflow. `apply` asks
for each environment that has one, before its confirmation; a repository in both lists
picks the platform or the app role. A dry run only notes the question, and an
unattended run (`YES=1`, or no terminal) always keeps the old value. The other way to
switch is a pull request that points `role-to-assume` at the new variable.

This needs the [`gh` CLI](https://cli.github.com) signed in as an admin of each
repository. Without it the GitHub step is skipped and says why; `CONFIGURE_GITHUB=false`
skips it on purpose. The step also catches a repository that does not exist or whose
name is spelled differently on GitHub — either would leave a trust policy that never
matches.

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

It only works if every deploy passes the role — `--role-arn ${{ vars.AWS_CFN_EXEC_ROLE_ARN }}`
in the workflow, or once per project:

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

- **VPCs and subnets.** Your VPCs are created by Terraform, after this runs. The
  optional security group only needs a VPC to exist, and the default VPC will do.
  **A function in the default VPC's subnets has no internet access** — they are public
  subnets, and Lambda never gives its network interfaces a public IP — so a function
  that calls anything outside AWS needs private subnets behind a NAT gateway, which
  this does not create.
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
| `make outputs`                           | Rebuilds `outputs/` from the accounts already applied. No AWS                                                        |
| `make examples`                          | Regenerates [`examples/`](examples/): the outputs for two made-up accounts                                           |
| `make setup`                             | Copies `bootstrap.env.example` to `bootstrap.env`, if you prefer editing to answering                                |
| `make lint` / `make test`                | shellcheck and JSON checks / plus four dry runs, no AWS needed                                                       |
| `make`                                   | Help                                                                                                                 |

`CONFIG=path` points every target at another config file — one per organisation, for
example. The scripts run directly too: `./bootstrap-account.sh --help`.

**Everything is asked for** when you run interactively, even what `bootstrap.env`
already says: its value is the default in `[brackets]`, so Enter confirms it and
anything else replaces it for this run (`-` clears an optional one, such as
`APP_REPOS`). Without a saved value there is a sensible default where one exists (your
organisation is guessed from the git remote of the directory you run it in). A value
set in the environment, or environments given as arguments, is not asked for. Answers can be saved to the config file; environments and the security
group are never saved, because they differ per account. With `--yes` (`YES=1`), or with no terminal — CI —
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

 GitHub
  my-org/api-service
    environment dev  CREATE, without protection rules
      AWS_ACCOUNT_ID         + 123456789012
      AWS_REGION             + us-east-1
      AWS_APP_ROLE_ARN       + arn:aws:iam::123456789012:role/app-deploy-role
      AWS_CFN_EXEC_ROLE_ARN  + arn:aws:iam::123456789012:role/app-cfn-exec-role
  my-org/infrastructure
    environment dev  exists, no protection rules: any branch can deploy
      AWS_ACCOUNT_ID         = 123456789012
      AWS_REGION             + us-east-1
      AWS_PLATFORM_ROLE_ARN  + arn:aws:iam::123456789012:role/platform-deploy-role
      AWS_DEPLOY_ROLE_ARN      GitHubActions-dev: apply asks whether to replace it
…                                     and worker-service

── app-exec-permissions.json
…                                     every rendered policy and trust document follows

Save these answers to ./bootstrap.env? [Y/n] y
  saved
```

From then on each question shows the saved answer, and Enter keeps it. `apply` shows
the same plan, without the documents, and asks before changing anything:

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

 GitHub
  my-org/api-service (dev): environment created, set AWS_ACCOUNT_ID AWS_REGION AWS_APP_ROLE_ARN AWS_CFN_EXEC_ROLE_ARN
  my-org/infrastructure (dev): set AWS_REGION AWS_PLATFORM_ROLE_ARN
  my-org/worker-service (dev): environment created, set AWS_ACCOUNT_ID AWS_REGION AWS_APP_ROLE_ARN AWS_CFN_EXEC_ROLE_ARN

Done:
  arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com
  arn:aws:iam::123456789012:role/platform-deploy-role
  arn:aws:iam::123456789012:role/app-deploy-role
  arn:aws:iam::123456789012:role/app-cfn-exec-role
  arn:aws:iam::123456789012:role/lambda-test-role

Ready to copy into the repositories:
  ./outputs/README.md
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

 GitHub
  my-org/api-service (dev): up to date
  my-org/billing-service (dev): environment created, set AWS_ACCOUNT_ID AWS_REGION AWS_APP_ROLE_ARN AWS_CFN_EXEC_ROLE_ARN
  my-org/infrastructure (dev): up to date
  my-org/worker-service (dev): up to date
```

Only the trust policies changed, and the new repository got its environment; the
permissions policies were compared and left alone.
A role's trust policy is always rewritten, even when the result is identical, and a
permissions policy prints `new default version` only when its JSON actually changed.

- **The lists replace, they do not add.** Each trust policy is rebuilt from the current
  `PLATFORM_REPOS` / `APP_REPOS` and environments. Give the full list every time: a run
  with only the new repository locks out all the others.
- **Change `bootstrap.env` to change the default.** An answer that differs from the
  file applies to that run only: the script never rewrites an existing config file —
  it prints the lines to set instead. For one run, an environment variable wins over the file:
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
- **GitHub variables and environments are never deleted.** A repository dropped from a
  list keeps its environment and its `AWS_*` variables, which then name a role it can no
  longer assume. Remove them by hand.

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
| `SECURITY_GROUP`                              | asked; `no` without a terminal     | Create the security group in this account. Never saved                |
| `SECURITY_GROUP_VPC_ID`                       | asked; the default VPC             | The VPC it goes in, in the first allowed region. Never saved          |
| `SECURITY_GROUP_NAME`                         | `app-default-sg`                   |                                                                       |
| `VPC_SSM_PREFIX`                              | `/default/vpc`                     | Prefix for `subnet_ids` and `security_group_id`. `""` to skip         |
| `CONFIGURE_GITHUB`                            | `true`                             | Create the GitHub environments and set their variables (needs `gh`)   |
| `OUTPUTS_DIR`                                 | `./outputs`                        | Where apply records accounts and writes the files to copy             |
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

| Statement                           | Effect                                                                                                                                                                                                                                                             |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ServicesAppsUse`                   | `<service>:*` for Lambda, API Gateway, Logs, CloudWatch, SQS, SNS, EventBridge, Scheduler, Firehose, DynamoDB, S3, SES                                                                                                                                             |
| `Parameters`                        | Create and update SSM parameters                                                                                                                                                                                                                                   |
| `DnsRecordsOnly`                    | Route 53 **records**, not zones                                                                                                                                                                                                                                    |
| `Reads`                             | Certificates for custom domains, VPC lookups for VPC-attached functions, secrets for `{{resolve:secretsmanager:…}}`, KMS for encrypted resources, ECR image pulls                                                                                                  |
| `FunctionRoles`                     | Create and manage the roles SAM generates for each function                                                                                                                                                                                                        |
| `PassRoleToAppServices`             | `iam:PassRole` only to Lambda, API Gateway, EventBridge, Scheduler, Firehose                                                                                                                                                                                       |
| `MacroTransforms`                   | `cloudformation:CreateChangeSet` on AWS's own transforms (`aws:transform/*`). A SAM template is `Transform: AWS::Serverless-2016-10-31`, and with `--role-arn` CloudFormation runs that transform as this role; without it every SAM deploy fails at the changeset |
| `ServiceLinkedRoles`                | Only API Gateway's                                                                                                                                                                                                                                                 |
| `DenyAttachingBroadManagedPolicies` | **Deny** attaching `AdministratorAccess`, `PowerUserAccess` or `IAMFullAccess` to any role                                                                                                                                                                         |

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

## Using the roles: the outputs

Every `apply` records the account it ran in under `outputs/accounts/` (git-ignored) and
renders, from **every account recorded so far**, files ready to copy into your
repositories. Apply in the dev account, then in the production account, and the files
cover both. [`examples/`](examples/) shows them for two made-up accounts.

| File                                                                      | Copy to                                                    |
| ------------------------------------------------------------------------- | ---------------------------------------------------------- |
| [`terragrunt/live/root.hcl`](examples/terragrunt/live/root.hcl)           | `infrastructure/live/root.hcl` in each platform repository |
| [`github-actions/terragrunt.yml`](examples/github-actions/terragrunt.yml) | `.github/workflows/` in each platform repository           |
| [`github-actions/sam-deploy.yml`](examples/github-actions/sam-deploy.yml) | `.github/workflows/` in each app repository                |
| [`README.md`](examples/README.md)                                         | — the accounts, and what to do before the first deploy     |

**`root.hcl`: the directory picks the account.** Units live at
`infrastructure/live/<env>/<region>/<component>/`, the layout platform-infrastructure
uses, and `root.hcl` maps each environment to its account, region, state bucket and
local profile. Switching between dev and production is `cd`:

```bash
aws sso login --profile dev
cd infrastructure/live/dev/us-east-1/vpc && terragrunt plan          # dev account
cd ../../../production/us-east-1/vpc     && terragrunt plan          # production account
```

Unlike platform-infrastructure's root config there is no hub: no shared-services role
in the middle, no `assume_role` in the provider. On your machine each environment uses
its own profile (exported credentials, as from `aws-vault exec`, win); in GitHub
Actions the job has already assumed `AWS_PLATFORM_ROLE_ARN` for the environment it runs
in. Either way `allowed_account_ids` makes a run with the wrong credentials fail before
it changes anything, and an environment missing from the map fails on the first line.
Each account keeps its state in its own bucket, `<org>-tfstate-<account>`, so no
cross-account bucket policy is needed.

The local profile recorded for an account is `PROFILE` (or the aws-vault or
`AWS_PROFILE` profile the run used), falling back to the environment's name.

**The workflows** run each job in the GitHub environment of the same name, which is
what the trust policy matches on and where the role ARNs and region come from:

- `terragrunt.yml` plans dev on a pull request, applies dev on a push to `main`, and
  plans or applies any environment from _Run workflow_ — in
  `infrastructure/live/<env>/`, so the directory and the role always agree.
- `sam-deploy.yml` deploys dev on a push to `main`, and any environment from _Run
  workflow_, as the stack `<repository>-<env>`, always passing `AWS_CFN_EXEC_ROLE_ARN`.

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

## Deploying the platform services

Two services are built to run in every account this bootstraps. Both are SAM
applications, so they deploy like any other app stack: `app-deploy-role` drives
CloudFormation, and `app-cfn-exec-role` creates the resources.

| Service                                                                                             | What it does                                                                                                                 | Capabilities                                    |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| [events-observability](https://github.com/jnet-platform-factory/events-observability)               | Indexes every event on an EventBridge bus into OpenSearch, with an error-alert digest, dead-letter queues and alarms         | `CAPABILITY_NAMED_IAM` `CAPABILITY_AUTO_EXPAND` |
| [aws-daily-monitoring-report](https://github.com/jnet-platform-factory/aws-daily-monitoring-report) | Emails the account's health every day — alarms, cost, Lambda, EventBridge, RDS — and optionally writes a JSON snapshot to S3 | `CAPABILITY_IAM`                                |

Each service's README is the reference for its parameters. This section covers how to
deploy them through the bootstrap's roles, and what to check before trusting them.

### Two ways to deploy them

**From your machine**, in your own SSO session. Clone the service, build it, and deploy
it with `--role-arn` set to the execution role, so the resources are created exactly as
CI would create them:

```bash
sam deploy --role-arn arn:aws:iam::123456789012:role/app-cfn-exec-role …
```

Leave `--role-arn` out and CloudFormation acts as you instead. That works too, but it
does not prove the execution role can do it.

**From CI**, with a small deployment repository of your own: list it in `APP_REPOS`,
[re-run the bootstrap](#re-running-adding-a-repository-or-an-environment), and copy
[`sam-deploy.yml`](examples/github-actions/sam-deploy.yml) into it. The service's
source goes in as a git submodule pinned to a release. Its per-environment parameters
go in your own `samconfig.toml`, which is where they belong: they name your addresses,
domains and buckets. The public repository is not the place for them. Make four changes
to the copied workflow:

1. `actions/checkout` with `submodules: true`.
2. `sam build --template <submodule>/template.yaml`, and `--use-container` for
   events-observability. Its dependencies include compiled wheels, which must match
   the Lambda runtime.
3. `--config-env "${STAGE}"` on `sam deploy`, so each GitHub environment reads its own
   section of `samconfig.toml`.
4. `--capabilities` from the table above. The generated workflow passes
   `CAPABILITY_IAM`, and events-observability's explicitly named roles need
   `CAPABILITY_NAMED_IAM`.

```toml
# samconfig.toml in the deployment repository — one section per GitHub environment
[dev.deploy.parameters]
parameter_overrides = "RecipientEmail=ops@example.com SenderEmail=reports@example.com AccountName=Dev"

[production.deploy.parameters]
parameter_overrides = "RecipientEmail=ops@example.com SenderEmail=reports@example.com AccountName=Production"
```

The workflow names the stack `<repository>-<env>`, so give each service its own
deployment repository, or its own job with its own `--stack-name`.

**Not yet: nesting the published application.** Both services are, or will be,
published to the Serverless Application Repository. A template that nests one, as an
`AWS::Serverless::Application`, does not deploy through `app-cfn-exec-role` today. SAM
expands the nested application by calling `serverlessrepo` and creates it as a nested
`AWS::CloudFormation::Stack`, and with `--role-arn` both happen as the execution role,
which has neither `serverlessrepo:*` nor CloudFormation stack permissions. Deploy from
source as above until it does.

### events-observability

Every event on a bus, indexed into an OpenSearch domain or Serverless collection
**that you own** — the stack does not create one. Its README's
[onboarding section](https://github.com/jnet-platform-factory/events-observability#onboarding-a-new-deployment)
is the long version. The order below matters because of the grant.

1. **Deploy with `CreateForwardingRule=false`.** The stack creates its role, but
   nothing that writes to the domain yet:

   ```bash
   git clone https://github.com/jnet-platform-factory/events-observability
   cd events-observability
   sam build --use-container
   sam deploy --stack-name events-observability-dev --resolve-s3 \
     --role-arn arn:aws:iam::123456789012:role/app-cfn-exec-role \
     --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
     --parameter-overrides NamePrefix=acme EnvironmentName=dev \
       OpenSearchEndpoint=search-acme-xxxx.us-east-1.es.amazonaws.com \
       "OpenSearchResourceArn=arn:aws:es:us-east-1:123456789012:domain/acme/*" \
       OpenSearchIndex=acme-events CreateForwardingRule=false AlertEmail=ops@example.com
   ```

2. **Grant the stack's role on the domain**, after the stack exists, never before.
   That is `ForwarderRoleArn` from the stack outputs, or `FirehoseDeliveryRoleArn` with
   `DeliveryMode=Firehose`. An OpenSearch access policy that names a principal which
   does not exist yet is rejected with `409 InvalidTypeException`, about 31 minutes
   after the update starts rather than when you submit it. Remove a grant before you
   delete the stack, for the same reason. If the domain is in another account, the
   grant is a change to that account's domain policy.
3. **Turn delivery on**: deploy again with `CreateForwardingRule=true`.
4. **Confirm the alarm subscription.** `AlertEmail` subscribes an address to the alarm
   topic, and the subscription stays `PendingConfirmation` until someone clicks the
   link. Until then every alarm is "successfully" delivered to nobody.

**One index per deployment** (`OpenSearchIndex`). The index has no explicit mapping, so
the first value written to a field fixes its type for good, for everyone writing to
that index.

**To check it works**, publish a marked event and read it back out of the index:

```bash
aws events put-events --entries '[{
  "Source":"acme.verify","DetailType":"Probe","EventBusName":"<the stack'\''s bus>",
  "Detail":"{\"organization\":\"probe-001\",\"username\":\"validator\"}"}]'
```

then search the index for `probe-001`. Expect exactly one document: two means a second
rule also feeds the forwarder, and none means the grant, the rule or the invoke
permission.

Against the execution role's policy, every resource type the template declares is
covered: functions, API Gateway v2, the bus and its rules, SQS, SNS, the Firehose
stream and its backup bucket, alarms, log groups, and the named roles with `PassRole`
to Lambda, EventBridge and Firehose. That was checked against the policy. It has not
been proved by a deploy in each delivery mode.

### aws-daily-monitoring-report

One email a day, at 10:00 UTC by default. It covers the account and region the stack
runs in. Two things must be in place first:

- **SES**: `SenderEmail` must be a verified identity in the stack's region, and so
  must `RecipientEmail` while the account's SES is in the sandbox.
- **Cost Explorer**: in a member account of an AWS Organization, the management account
  must enable member-account access to billing data. Without it the report still sends,
  and its cost section says Cost Explorer is unavailable.

```bash
git clone https://github.com/jnet-platform-factory/aws-daily-monitoring-report
cd aws-daily-monitoring-report
sam build
sam deploy --stack-name aws-daily-monitoring-report --resolve-s3 \
  --role-arn arn:aws:iam::123456789012:role/app-cfn-exec-role \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides RecipientEmail=ops@example.com SenderEmail=reports@example.com \
    AccountName=Dev
```

The stack is one function, its role, and a schedule, all within the execution role's
policy. The function has a fixed name, `aws-daily-monitoring-report`, so two stacks in
one account and region (one per stage) need `FunctionNameSuffix`.

**The snapshot is opt-in.** Set `SnapshotBucket` and `SnapshotSlug` and each run also
writes `<prefix><slug>.json`, for a dashboard to read. The bucket is not created by the
stack. If it lives in another account, that bucket's policy must grant this account
`s3:PutObject` and `s3:PutObjectAcl` on the prefix first. Until then every write fails
with 403, and the email still arrives.

**To check it works**, send a report now:

```bash
aws lambda invoke --function-name aws-daily-monitoring-report \
  --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout
```

Expect `"statusCode": 200` and an email within a minute. With a snapshot bucket set,
`"snapshotWritten": true` is the only proof the snapshot landed.

## Requirements

- AWS CLI v2, and IAM admin in the target account
- `python3` (standard library only)
- `bash` 3.2 or later — the macOS system bash works

## License

[Apache-2.0](LICENSE)
