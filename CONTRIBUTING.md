# Contributing

Thank you for your interest in contributing to this project.

## Getting Started

1. Fork the repository and clone it locally.
2. Install [Terraform](https://developer.hashicorp.com/terraform/install) (>= 1.5) and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html).
3. Configure AWS credentials with access to both `us-east-1` and `eu-west-1`.

## Development Workflow

```bash
# Validate formatting
terraform fmt -recursive -check

# Validate configuration
terraform validate

# Plan before applying
terraform plan -var-file=environments/<env>/terraform.tfvars
```

## Submitting Changes

1. Create a branch from `main` with a descriptive name (`feature/...`, `fix/...`, `docs/...`).
2. Keep changes focused — one logical change per pull request.
3. Run `terraform fmt -recursive` before committing so all `.tf` files are consistently formatted.
4. Write a clear PR description that explains *what* changed and *why*.
5. Ensure `terraform validate` passes for all affected modules.

## Module Guidelines

- Each module in [modules/](modules/) must expose clear `variables.tf` and `outputs.tf`.
- Avoid hardcoded region strings — use variables so modules stay region-agnostic.
- Document any non-obvious variable with a `description` in its `variable` block.
- Do not commit real AWS account IDs, ARNs, or credentials.

## Reporting Issues

Open a GitHub issue with:
- A short description of the problem.
- The Terraform version (`terraform version`) and AWS provider version.
- Relevant error output or plan output (redact any sensitive values).

## Code of Conduct

Be respectful and constructive. Contributions of all sizes are welcome.
