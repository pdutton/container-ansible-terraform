# No providers and no backend: `terraform init` needs no registry access, so the
# smoke test runs fully offline. terraform_data is a builtin managed resource
# (Terraform 1.4+), which makes this more than a syntax check -- it exercises the
# real init -> plan -> apply -> state path.
variable "greeting" {
  type    = string
  default = "ok"
}

resource "terraform_data" "smoke" {
  input = var.greeting
}

output "message" {
  value = "${terraform_data.smoke.output}-from-terraform"
}
