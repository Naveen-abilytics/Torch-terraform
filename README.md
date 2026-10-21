# sample-app — ECS on Fargate, deployed by GitHub Actions, managed by Terraform

A complete, working reference stack. Push to `main`, the pipeline builds the image,
produces a Terraform plan, **stops and waits for your approval**, then applies it.

## Constraints this stack honours

| Constraint | How it is honoured |
|---|---|
| **No VPC** | Zero VPC, subnet, route table, IGW or NAT resources are created. The stack reads the account's existing default VPC through `data` sources and places the task in its default public subnet. |
| **No S3** | No bucket. The image lives in **ECR** (a registry, not a bucket). Terraform state is carried in the GitHub Actions cache, not in S3. |
| **No database** | No RDS, no DynamoDB. The app is stateless; state lives in the process. |
| **High-level config** | One `aws_ecs_service`, one `aws_ecs_task_definition`, one `aws_ecr_repository`. No load balancer, no auto-scaling, no bespoke IAM sprawl. |
| **Deploy needs permission** | The `deploy` job is bound to the GitHub Environment `production`. With a required reviewer configured, the run parks in **"Waiting for approval"** until you approve it. |

> **Why a VPC is involved at all:** ECS/Fargate is bound to a VPC by the API — there is no
> "VPC-less" ECS. The way to honour *no VPC* is to create none and reuse the one your
> account already has. If your account has no default VPC, create one in the console
> (EC2 → VPCs → Create VPC, with auto-created subnets) or set `ecs_subnet_ids`.

## Architecture

```
main ──► [build & plan]  (runs on every push, no approval needed)
          ├─ OIDC → AWS (short-lived credentials, no keys)
          ├─ terraform apply -target=ECR repo   (repo must exist before the image)
          ├─ docker build + push → ECR
          └─ terraform plan -out=tfplan  → job summary + artifact
                        │
                        ▼
           [deploy]  environment: production   ◄── YOU APPROVE HERE
                        │
                        ├─ terraform apply tfplan
                        ├─ smoke test the public endpoint
                        └─ state persisted to the Actions cache
```

## Repository layout

```
.
├── app/                     # the sample application (Node 22, zero dependencies)
│   ├── Dockerfile
│   ├── package.json
│   └── server.js
├── terraform/               # the stack that gets deployed
│   ├── ecs.tf               # cluster, task definition, service, security group
│   ├── ecr.tf               # image repository + lifecycle policy
│   ├── iam.tf               # execution role + task role
│   ├── data.tf              # default VPC lookup (creates nothing)
│   ├── variables.tf
│   ├── outputs.tf
│   └── tests/plan.tftest.hcl# offline plan via the mock provider
├── bootstrap-oidc/          # ONE-TIME admin bootstrap: GitHub OIDC provider + role
│   ├── main.tf             #   trust policy + scoped CI permissions
│   ├── terraform.tfvars    #   set github_org + github_repo (git-ignored)
│   └── tests/              #   offline plan via the mock provider
├── scripts/
│   ├── setup-github-env.ps1   # creates the environment + repo variables
│   └── setup-github-secrets.ps1# uploads AWS keys as secrets, sets AWS_AUTH_MODE=static
└── .github/workflows/deploy.yml
```

---

# Setup

There are **two** ways to authenticate GitHub Actions to AWS. Both are supported by the
same workflow — the `AWS_AUTH_MODE` repository variable picks between them.

| | Method A — OIDC (recommended) | Method B — static secret |
|---|---|---|
| GitHub stores | nothing | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Credential lifetime | ~1 hour, minted per run | long-lived, until rotated |
| Needs an AWS role | yes | an IAM user |
| `AWS_AUTH_MODE` | `oidc` (default) | `static` |
| Extra setup | register the OIDC provider | create an IAM user + key |

**Method B is the escape hatch.** If the OIDC provider cannot be registered in your
account, or you just want to get moving, use it — the pipeline behaves identically.

## 1. Create the CI identity in AWS (admin, local AWS credentials)

Both methods start here. `bootstrap-oidc/` creates the OIDC role and, optionally, a
scoped IAM user for Method B. They share one permissions policy.

```bash
cd bootstrap-oidc
terraform init
terraform plan
terraform apply
```

`terraform.tfvars` already exists and is pre-filled for this repo
(`Naveen-abilytics/Torch-terraform`, account `008971661427`). Edit it if needed:

```hcl
github_org   = "Naveen-abilytics"
github_repo  = "Torch-terraform"
aws_region   = "us-east-1"
expected_account_id = "008971661427"   # guard: refuses to run against another account
```

### Method A — OIDC

```hcl
create_oidc_role     = true
create_oidc_provider = true    # let Terraform register the provider
create_static_user   = false
```

Apply creates the OIDC provider, the role `github-actions-ecs-deploy`, and the shared
permissions policy. Take the `role_arn` output → that is `AWS_ROLE_ARN`.

> **`create_oidc_provider = false`** means "the account already has the provider". If the
> account does **not** have it, the role creation fails with:
> `Invalid principal: OIDC provider token.actions.githubusercontent.com does not exist`.
> That is the "still asking for an OIDC provider" symptom — flip it back to `true`.

#### Already have the provider? Paste its ARN

If the account already has the GitHub OIDC provider, **never let Terraform create it** —
and give Terraform the real ARN so the trust policy references it verbatim:

```hcl
create_oidc_role           = true
create_oidc_provider       = false
existing_oidc_provider_arn = "arn:aws:iam::008971661427:oidc-provider/token.actions.githubusercontent.com"
```

Find the ARN:

```bash
aws iam list-open-id-connect-providers
# or: IAM console -> Identity providers -> GitHub Actions -> Provider ARN
```

With `existing_oidc_provider_arn` set, Terraform skips the provider entirely
(`count = 0`) and uses your ARN in the role's trust policy. Leave it empty and the ARN
is derived from the account id — same result, less typing.

> The provider ARN must belong to the **same account** as the role
> (`008971661427`). A provider ARN from a different account is rejected by AWS with
> `Invalid principal`.

### Method B — static secret

```hcl
create_oidc_role     = false   # <- do not create an OIDC role at all
create_oidc_provider = false   # <- do not touch the OIDC provider
create_static_user   = true
```

Apply creates **only** the shared permissions policy, the IAM user `github-actions-ecs`,
and an access key. Nothing OIDC-related is touched, so this works even when the
account cannot register `token.actions.githubusercontent.com`. Take
`static_access_key_id` and `static_secret_access_key` from the outputs.

## 2. GitHub: secrets and variables

### Method A (OIDC) — variables only, no secrets

Repo → **Settings → Secrets and variables → Actions → Variables**:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::008971661427:role/github-actions-ecs-deploy` |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPOSITORY` | `sample-app` |
| `AWS_AUTH_MODE` | `oidc` |

### Method B (static secret) — one secret, plus variables

Repo → **Settings → Secrets and variables → Actions → Secrets** → *New repository secret*:

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | from `static_access_key_id` |
| `AWS_SECRET_ACCESS_KEY` | from `static_secret_access_key` |

*(`AWS_SESSION_TOKEN` is optional — only needed for temporary/SSO credentials.)*

Repo → **Variables**:

| Name | Value |
|---|---|
| `AWS_AUTH_MODE` | `static` |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPOSITORY` | `sample-app` |

Or do the whole thing in **one command** — it applies the bootstrap in static mode,
reads the *scoped* CI key out of the Terraform outputs, uploads both secrets, and sets
`AWS_AUTH_MODE=static`:

```powershell
.\scripts\setup-github-secrets.ps1
```

Add `-ShowCredentials` if you also want a copy of the key printed for your records.

> The script uploads the **scoped CI user** key that the bootstrap creates — never your
> personal admin key. It deliberately does not read a key out of
> `%USERPROFILE%\.aws\credentials`, because that would hand your whole AWS account to
> every workflow run.
>
> It also refuses to run if the active AWS credentials belong to an account other than
> `008971661427`.

Secrets are write-only: GitHub encrypts them with the repository's public key, so they
can never be read back — not by you, not by GitHub, not by the script.

> **The OIDC provider ARN is not a GitHub secret.** It belongs in the **role's trust
> policy** in AWS, and nothing else. Putting it in a secret (or in `AWS_ROLE_ARN`)
> does not help — `role-to-assume` needs the **role** ARN
> (`arn:aws:iam::008971661427:role/github-actions-ecs-deploy`), and the provider ARN
> only ever appears inside the trust policy that AWS evaluates.

### Automation

```powershell
# environment + variables (both methods)
.\scripts\setup-github-env.ps1 -AwsRoleArn arn:aws:iam::008971661427:role/github-actions-ecs-deploy

# bootstrap in static mode + upload the key pair + AWS_AUTH_MODE=static
.\scripts\setup-github-secrets.ps1
```

## 3. GitHub environment — this is the approval gate

Repo → **Settings → Environments → New environment** → name it `production`
(this must match `github_environment` in the bootstrap and `environment:` in the workflow).

Then, in the environment:

1. **Deployment protection rules → Required reviewers** → add yourself.
2. *(optional)* **Deployment branches and tags** → limit to `main`.

With a required reviewer set, the `deploy` job stops at `Waiting for approval` and shows
an **Approve and deploy** button. Nobody — including you — can bypass it except by
disabling the protection rule.

> The environment and the repository variables can be created automatically:
>
> ```powershell
> # after the bootstrap, so AWS_ROLE_ARN can be registered too
> .\scripts\setup-github-env.ps1 -AwsRoleArn arn:aws:iam::123456789012:role/github-actions-ecs-deploy
> ```
>
> The **required reviewer** still has to be added in the UI: GitHub's API for that rule
> only accepts GitHub App requests, so a personal access token gets
> `422 App not installed on organization`. The script prints a reminder.

### Method A in detail — how OIDC works

**The problem it solves.** The classic setup stores `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` in GitHub Secrets. Those are long-lived, leak from logs and
backups, and are painful to rotate.

**The mechanism.**

1. The workflow declares `permissions: id-token: write`.
2. `aws-actions/configure-aws-credentials` asks GitHub for an **OIDC token** — a short-lived
   JWT signed by GitHub, whose payload contains the repository, ref, workflow and
   environment.
3. AWS **STS** validates that JWT against the registered OIDC provider, checks the trust
   policy, and hands back **temporary credentials** (default 1 hour).
4. The keys never existed anywhere. Rotate by editing the role.

**The trust policy** (`bootstrap-oidc/main.tf`) is the whole security boundary:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": [
        "repo:<org>/<repo>:ref:refs/heads/main",
        "repo:<org>/<repo>:environment:production"
      ]
    }
  }
}
```

The `sub` claim is what binds a run to a job:

| Job | `sub` claim | Consequence |
|---|---|---|
| `build` | `repo:org/repo:ref:refs/heads/main` | Can build, push and **plan** |
| `deploy` | `repo:org/repo:environment:production` | Can **apply** — and the environment only grants that `sub` *after* a reviewer approves |

> **There is no `:branch:` subject in GitHub OIDC.** A branch push presents
> `repo:<org>/<repo>:ref:refs/heads/<branch>`. A trust policy listing
> `repo:<org>/<repo>:branch:main` will fail with
> `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
> The workflow prints the live `sub` claim in the **Show OIDC token claims** step
> so you can compare it against the trust policy at a glance.

So the approval gate is enforced twice: by GitHub (the environment protection rule) and
by AWS (the trust policy will not issue credentials to an unapproved subject).

**Audience** — the provider is registered with `client_id_list = ["sts.amazonaws.com"]` and
the workflow passes `audience: sts.amazonaws.com`, so `aud` matches. Do not change one
without the other.

## 2. GitHub repository variables

Repo → **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | the `role_arn` output from step 1 |
| `AWS_REGION` | `us-east-1` (or your region) |
| `ECR_REPOSITORY` | `sample-app` — must match `var.app_name` |

There are **no secrets** to add. That is the point of OIDC.

## 3. GitHub environment — this is the approval gate

Repo → **Settings → Environments → New environment** → name it `production`
(this must match `github_environment` in the bootstrap and `environment:` in the workflow).

Then, in the environment:

1. **Deployment protection rules → Required reviewers** → add yourself.
2. *(optional)* **Deployment branches and tags** → limit to `main`.

With a required reviewer set, the `deploy` job stops at `Waiting for approval` and shows
an **Approve and deploy** button. Nobody — including you — can bypass it except by
disabling the protection rule.

> The environment and the repository variables can be created automatically:
>
> ```powershell
> # after the bootstrap, so AWS_ROLE_ARN can be registered too
> .\scripts\setup-github-env.ps1 -AwsRoleArn arn:aws:iam::123456789012:role/github-actions-ecs-deploy
> ```
>
> The **required reviewer** still has to be added in the UI: GitHub's API for that rule
> only accepts GitHub App requests, so a personal access token gets
> `422 App not installed on organization`. The script prints a reminder.

## 4. Push it

```bash
git init
git add .
git commit -m "feat: ECS Fargate sample app via Terraform and GitHub Actions"
git remote add origin git@github.com:<org>/<repo>.git
git push -u origin main
```

The first run creates the ECR repo, pushes the image, shows the plan, then waits for you.

---

# Working on it locally

```bash
cd terraform
terraform init
terraform plan                  # real plan, needs AWS credentials
terraform apply                 # creates the stack
```

Render the plan **without any AWS credentials** (mock provider):

```bash
cd terraform
terraform test -verbose
```

Useful commands once it is up:

```bash
aws ecs list-tasks --cluster sample-app --service-name sample-app --query 'taskArns[0]' --output text
aws ecs describe-tasks --cluster sample-app --tasks <task-arn> \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4`].value | [0]' --output text
curl http://<ip>:8080/health
```

Tear down: `terraform destroy` in `terraform/`.

---

## Notes and trade-offs

* **State** — no S3 backend (you asked for no S3), so CI persists `terraform.tfstate` in
  the GitHub Actions cache. It works, but the cache is branch-scoped and evicted after 7
  days of inactivity. For anything real, point the backend at **HCP Terraform** or
  **Terraform Cloud**, which is also S3-free.
* **Task networking** — the task gets a public IP and the container port is published
  directly. No load balancer, so there is no DNS name and no TLS. Put an ALB in front if
  you need one.
* **Public exposure** — port 8080 is open to `0.0.0.0/0` by default. Restrict it with
  `var.allowed_cidr`.
* **The task role has no policies.** The sample app makes no AWS API calls, so it gets no
  permissions. Add policies to `aws_iam_role.task` when your app needs them.
* **`-target=aws_ecr_repository.app`** in the workflow is deliberate: an ECS service can
  only reference an image that already exists in ECR, so the repository is created first,
  the image is pushed, and only then does the full plan run.

---

## Troubleshooting

### `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`

STS received the token and rejected it. In order of likelihood:

1. **The `sub` claim in the trust policy is wrong.** GitHub OIDC has **no**
   `:branch:` subject. A push to a branch presents
   `repo:<org>/<repo>:ref:refs/heads/<branch>`. The workflow's **Show OIDC token
   claims** step prints the live `sub` — compare it with the trust policy:

   ```powershell
   aws iam get-role --role-name github-actions-ecs-deploy `
     --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike' --output json
   ```

2. **The trust policy was edited in AWS but not in Terraform.** Re-apply the
   bootstrap so the two agree, or Terraform will revert your manual edit on the
   next apply.

3. **The provider ARN is wrong.** The trust policy's `Principal.Federated` must be
   the provider ARN for *this* account. Verify:

   ```powershell
   aws iam get-open-id-connect-provider `
     --open-id-connect-provider-arn arn:aws:iam::008971661427:oidc-provider/token.actions.githubusercontent.com `
     --query '{Url:Url, ClientIds:ClientIdList}'
   ```

   `Url` must be `https://token.actions.githubusercontent.com` and `ClientIds` must
   contain `sts.amazonaws.com`.

4. **The wrong ARN is in `AWS_ROLE_ARN`.** `role-to-assume` needs the **role** ARN
   (`arn:aws:iam::008971661427:role/github-actions-ecs-deploy`), never the
   **provider** ARN. The provider ARN only belongs inside the trust policy.

### `Could not load credentials from any providers`

`AWS_AUTH_MODE` is `oidc` but the secrets are missing, or it is `static` but
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are not set. Check both:

```powershell
gh variable list --repo Naveen-abilytics/Torch-terraform
gh secret list --repo Naveen-abilytics/Torch-terraform
```

### `Invalid principal: OIDC provider token.actions.githubusercontent.com does not exist`

The account has no OIDC provider. Either let Terraform create it
(`create_oidc_provider = true`) or switch to Method B
(`create_oidc_role = false`, `create_static_user = true`).

### The apply never pauses for approval

The environment protection rule is missing. Repo → **Settings → Environments** →
`production` → **Deployment protection rules** → **Required reviewers**. The GitHub
API rejects PATs for this (`422 App not installed on organization`), so it has to be
done in the UI.
