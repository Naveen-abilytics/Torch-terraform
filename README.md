# sample-app — ECS on Fargate, image built by GitHub Actions, managed by Terraform

A complete, working reference stack. Push to `main`, the pipeline builds the image,
smoke-tests it, and pushes it to **ECR**. It does **not** deploy: the ECS service is
created by Terraform when you choose to run it.

All application configuration lives in **AWS Secrets Manager** and is injected into the
ECS task at runtime. The pipeline holds **no AWS credentials** — it brokers a key pair
out of Secrets Manager on each run.

## Constraints this stack honours

| Constraint | How it is honoured |
|---|---|
| **No VPC** | Zero VPC, subnet, route table, IGW or NAT resources are created. The stack reads the account's existing default VPC through `data` sources and places the task in its default public subnet. |
| **No S3** | No bucket. The image lives in **ECR** (a registry, not a bucket). Terraform state is carried in the GitHub Actions cache, not in S3. |
| **No database** | No RDS, no DynamoDB. The app is stateless; state lives in the process. |
| **Build only, no deploy** | The workflow ends at "image pushed to ECR". There is no deploy job, no environment gate and no `terraform apply` of the service. |
| **High-level config** | One `aws_ecs_service`, one `aws_ecs_task_definition`, one `aws_ecr_repository`. No load balancer, no auto-scaling, no bespoke IAM sprawl. |

> **Why a VPC is involved at all:** ECS/Fargate is bound to a VPC by the API — there is no
> "VPC-less" ECS. The way to honour *no VPC* is to create none and reuse the one your
> account already has. If your account has no default VPC, create one in the console
> (EC2 → VPCs → Create VPC, with auto-created subnets) or set `ecs_subnet_ids`.

## Architecture

```
main / PR ──► [build]        (always runs: no AWS, no credentials)
               ├─ docker build
               ├─ run the container
               ├─ curl /health until it answers
               └─ assert the injected config reached the app
                        │
                        ▼
              [push]         (main only, needs the reader secret)
               ├─ broker: reader key → read ONE secret → deploy key pair
               ├─ terraform apply -target=<ECR repo>   (repo must exist first)
               ├─ docker build + push → ECR
               └─ done. Nothing is deployed.
```

The `deploy.yml` filename is kept only because the workflow is registered under it; the
workflow itself no longer deploys.

## How credentials work — the Secrets Manager broker

There is **no OIDC** here and **no AWS key stored in GitHub** in the usual sense. What
GitHub holds is one deliberately weak credential:

```
GitHub secret  →  reader key pair
                     │  can read exactly one secret, nothing else
                     ▼
              AWS Secrets Manager: sample-app/ci-credentials
                     │  holds the deploy key pair
                     ▼
              deploy identity  →  used by terraform / docker / aws cli
```

| Identity | Where its key lives | What it can do |
|---|---|---|
| `github-actions-secrets-reader` | GitHub secret `SM_READER_ACCESS_KEY_ID` / `SM_READER_SECRET_ACCESS_KEY` | Read **one** secret. Cannot deploy, cannot create anything. |
| `github-actions-ecs-deploy` | AWS Secrets Manager only | Everything the pipeline needs: ECR, ECS, Logs, scoped IAM, the app-config secret. |

The deploy key is **never** printed, **never** committed and **never** uploaded to GitHub.
`scripts/broker-aws-credentials.sh` fetches it at runtime, writes it to the runner's
`~/.aws/credentials` (mode `0600`), and every later step picks it up automatically. The
credentials are deleted from the runner by a final `Scrub brokered credentials` step.

If the reader key leaks, the attacker gets one secret value — not your account. Rotate the
reader (see *Rotating credentials*) and move on.

## Repository layout

```
.
├── app/                          # the sample application (Node 22, zero dependencies)
│   ├── Dockerfile
│   ├── package.json
│   └── server.js                 # reads APP_* values injected from Secrets Manager
├── terraform/                    # the stack (applied by you, not by CI)
│   ├── ecs.tf                    # cluster, task definition, service, security group
│   ├── secrets.tf                # app-config secret + version
│   ├── ecr.tf                    # image repository + lifecycle policy
│   ├── iam.tf                    # execution role + task role (both may read the secret)
│   ├── data.tf                   # default VPC lookup (creates nothing)
│   ├── variables.tf
│   ├── outputs.tf
│   └── tests/plan.tftest.hcl     # offline plan via the mock provider
├── bootstrap-ci/                 # ONE-TIME admin bootstrap: the two CI identities
│   ├── main.tf                   #   reader + deploy users, policies, credentials secret
│   ├── versions.tf               #   provider + version config
│   ├── terraform.tfvars          #   filled in, git-ignored
│   └── tests/plan.tftest.hcl     #   offline plan via the mock provider
├── scripts/
│   ├── register-ci-identity.ps1  # one command: apply bootstrap + upload the reader key
│   ├── broker-aws-credentials.sh # runs ON THE RUNNER: fetches the deploy key
│   └── setup-github-env.ps1      # repository variables (+ optional environment)
└── .github/workflows/deploy.yml  # build + push to ECR only (no deploy)
```

---

# Setup

## 1. Push it

```powershell
git push origin main
```

The **build** job runs immediately and needs nothing from AWS: it builds the image, runs
it, and curls `/health` until the container answers. On a pull request that is all that
happens.

On `main`, the **push** job then publishes the image to ECR. It is skipped automatically
if the reader secret has not been registered yet, so the build job always gives you a
green signal.

## 2. Publish the image to ECR (optional, once)

The push job needs the Secrets Manager broker, which needs a one-time bootstrap with AWS
admin credentials:

```powershell
aws configure                 # or: aws login
aws sts get-caller-identity   # must print 008971661427
.\scripts\register-ci-identity.ps1
```

That command:

1. applies `bootstrap-ci/`, creating the reader, the deploy identity, and the
   `sample-app/ci-credentials` secret that holds the deploy key pair;
2. uploads the **reader** key to GitHub as `SM_READER_ACCESS_KEY_ID` /
   `SM_READER_SECRET_ACCESS_KEY`;
3. sets the `CI_CREDENTIALS_SECRET_ARN` repository variable.

It refuses to run against any account other than `008971661427`. Until you run it, the
`push` job is skipped and the pipeline still succeeds.

## 3. Deploy the stack (when you want to)

Nothing in the pipeline deploys. The ECS cluster, task definition, service and secret are
created by Terraform, run deliberately by you:

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

Once the service exists, pick up a newly pushed image with:

```powershell
aws ecs update-service --cluster sample-app --service sample-app --force-new-deployment
```

---

# The application configuration

The app's config is a single JSON secret, `sample-app/app-config`, defined by
`var.app_config` in `terraform/variables.tf`:

```hcl
app_config = {
  APP_MESSAGE = "Hello from AWS Secrets Manager"
  APP_REGION  = "us-east-1"
}
```

Every key becomes an environment variable in the container. The task definition uses the
ECS `secrets` block, not plain `environment`:

```hcl
secrets = [
  { name = "APP_MESSAGE", valueFrom = "<secret-arn>::APP_MESSAGE" },
  { name = "APP_REGION",  valueFrom = "<secret-arn>::APP_REGION" },
]
```

The ECS agent resolves those at task start using the **execution role**, so the values
never appear in the task definition, the image, or the plan output.

To change a value, edit `var.app_config` and run `terraform apply` — a new secret version
is written and the task definition rolls on the next deployment.

Verify what the container actually received:

```powershell
# the whole config, straight from Secrets Manager
$arn = terraform -chdir=terraform output -raw app_config_secret_arn
aws secretsmanager get-secret-value --secret-id $arn --query SecretString --output text | ConvertFrom-Json

# and what the app made of it (names only; values are never exposed)
curl "http://<task-ip>:8080/info"
```

`/info` deliberately returns only the **names** of the injected keys, never the values —
so the endpoint stays safe to expose.

## Rotating credentials

**Rotate the deploy key** (rarely needed):

```powershell
cd bootstrap-ci
terraform apply -replace=aws_iam_access_key.ci_deploy
.\..\scripts\register-ci-identity.ps1 -SkipApply
```

`aws_iam_access_key.ci_deploy` is the only resource replaced, and the new key is written
straight into the secret. The old key is destroyed with the resource.

**Rotate the reader key** (do this if the GitHub secret ever leaks):

```powershell
cd bootstrap-ci
terraform apply -replace=aws_iam_access_key.ci_reader
.\..\scripts\register-ci-identity.ps1 -SkipApply
```

Then delete the old key in the AWS console if you want it gone immediately.

---

# How it works, in detail

## The broker script

`scripts/broker-aws-credentials.sh` runs as a step in **both** jobs. It:

1. validates that `CI_CREDENTIALS_SECRET_ARN` and the reader key are present, and that
   `aws` and `jq` exist on the runner;
2. calls `secretsmanager:GetSecretValue` with the reader key, inside a `::group::` so the
   output collapses;
3. parses `access_key_id` / `secret_access_key` out of the JSON;
4. writes `~/.aws/credentials` and `~/.aws/config` under `umask 077`, then `chmod 600`;
5. calls `sts get-caller-identity` and prints the resulting ARN, so the log proves which
   identity was actually assumed.

It never echoes the secret. The AWS CLI, Terraform and Docker all read the shared
credentials file without any further configuration.

## Why the reader's policy uses a name pattern

Secrets Manager appends a random six-character suffix to every secret ARN, so the ARN is
not known until the secret exists. The bootstrap therefore scopes the reader with:

```
arn:aws:secretsmanager:<region>:<account>:secret:sample-app/ci-credentials-*
```

combined with a `secretsmanager:SecretTag/Project` condition. The policy is a plain
`jsonencode()` expression rather than an `aws_iam_policy_document` data source, which keeps
it fully assertable in the offline plan test (`terraform test` needs no AWS account).

## State and secrets

- Terraform state is carried between runs in the **GitHub Actions cache**
  (`tfstate-final-<run_id>` wins, most recent). No S3 bucket.
- The state contains the app config values, because Terraform wrote them. Treat it as a
  secret. The cache is repo-scoped and encrypted at rest by GitHub.
- For anything real, point the backend at **HCP Terraform / Terraform Cloud** — also
  S3-free — and mark `app_config` as sensitive in your workspace.

## Why `-target=aws_ecr_repository.app`

An ECS service can only reference an image that already exists in ECR. The workflow
therefore creates the repository first, pushes the image, and only then runs the full plan.

---

## Notes and trade-offs

* **The deploy key is long-lived.** That is inherent to the design you chose — no OIDC, no
  STS session. Mitigation is that it lives in one place (Secrets Manager), is scoped to
  this project, and the reader key in GitHub cannot do anything with it. For a keyless
  variant, OIDC is the alternative, but it requires the role's trust policy to be exactly
  right (the `sub` claim for a branch push is `repo:org/repo:ref:refs/heads/main`, **not**
  `:branch:main`).
* **The reader key in GitHub is still a secret.** If it leaks, rotate it — the blast radius
  is a single secret value.
* **Task networking** — the task gets a public IP and the container port is published
  directly. No load balancer, so there is no DNS name and no TLS.
* **Public exposure** — port 8080 is open to `0.0.0.0/0` by default. Restrict it with
  `var.allowed_cidr`.
* **Secret values in state** — Terraform records `var.app_config` in the state file. This
  is a sample, but in production use a remote backend with encryption and access control.

---

## Troubleshooting

### `Broker AWS credentials from Secrets Manager` fails

Read the message. The script distinguishes the cases:

| Message | Cause |
|---|---|
| `CI_CREDENTIALS_SECRET_ARN is not set` | the repository variable is missing — run `register-ci-identity.ps1` |
| `The reader credentials are missing` | `SM_READER_ACCESS_KEY_ID` / `SM_READER_SECRET_ACCESS_KEY` are not set |
| `Could not read <arn> with the reader key` | the reader's policy no longer grants access, or the secret was deleted |
| `did not contain access_key_id and secret_access_key` | the secret was overwritten with a different shape |

### `AccessDenied` later in the run (during plan or apply)

The broker succeeded but the **deploy** identity is missing a permission. Check what your
change needs and extend `local.ci_deploy_policy` in `bootstrap-ci/main.tf`, then re-run
`register-ci-identity.ps1`.

### The task starts and immediately stops

Check the app-config secret was readable by the execution role:

```powershell
aws logs tail /ecs/sample-app --since 10m
```

A `ResourceInitializationError: unable to pull secrets` line means the execution role's
`ReadAppConfig` policy does not cover the secret ARN. Both roles carry that policy now, so
this usually means the stack was applied from a stale plan.

### The `push` job is skipped

Two reasons, both benign: the run was a pull request, or `CI_CREDENTIALS_SECRET_ARN` is not
set yet. Run `register-ci-identity.ps1` to enable it. The `build` job is the real gate and
runs regardless.

### A re-run shows an error the current code cannot produce

**"Re-run all jobs" replays the workflow file from the run's original commit**, not from
`main`. A run started before the rewrite will keep failing the same way, forever, no matter
what you push:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That message is from the retired OIDC workflow. Check the commit the run used
(`gh run view <id> --json headSha`) before believing it. To test the current code, push a
commit or use **Actions → Build (ECS Fargate image) → Run workflow** on `main`; do not
re-run an old run.

### `/info` shows `"source": "none"`

The container started without any `APP_*` variables, so the `secrets` block did not
resolve. Confirm `var.app_config` is non-empty and that the task definition shows a
`secrets` array (not just `environment`).
