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
└── .github/workflows/deploy.yml
```

---

# Setup

## 1. One-time: create the GitHub OIDC role (admin, local AWS credentials)

GitHub Actions must be able to reach AWS *before* the workflow can run, so the role is
bootstrapped out of band. Run this once, from a machine with working AWS credentials:

```bash
cd bootstrap-oidc
terraform init
terraform apply
```

`terraform.tfvars` already exists — edit it and set `github_org` + `github_repo` to your
repo. It currently has `create_oidc_provider = false`, which tells Terraform that your
account **already** has the GitHub OIDC provider registered, so it will not try to create
it and will reference the existing provider by ARN instead.

It creates:

* `aws_iam_role.github_actions` — trust policy scoped to exactly two subjects
* a scoped inline policy (ECR / ECS / Logs / IAM on the two ECS roles only)

Output `role_arn` → this is the value of the GitHub variable `AWS_ROLE_ARN`.

> If your account does **not** already have the provider, flip `create_oidc_provider` back
> to `true` in `terraform.tfvars` and Terraform will create it for you.

### The OIDC method in detail

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
        "repo:<org>/<repo>:branch:main",
        "repo:<org>/<repo>:environment:production"
      ]
    }
  }
}
```

The `sub` claim is what binds a run to a job:

| Job | `sub` claim | Consequence |
|---|---|---|
| `build` | `repo:org/repo:branch:main` | Can build, push and **plan** |
| `deploy` | `repo:org/repo:environment:production` | Can **apply** — and the environment only grants that `sub` *after* a reviewer approves |

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
#   T o r c h - t e r r a f o r m  
 