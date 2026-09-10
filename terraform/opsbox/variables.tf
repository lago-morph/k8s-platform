variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Short environment label applied to all resource tags"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = <<-EOT
    Instance type for the ops box. It runs shell scripts and waits, so the
    smallest usable type is right. Kept small deliberately: the sandbox
    account carries a 9-instance cap and the platform itself wants 6
    (3 hub nodes, 2 spoke, 1 relay), so this must not be the instance that
    makes a build fail for quota.
  EOT
  type        = string
  default     = "t3.small"
}

variable "repo_url" {
  description = <<-EOT
    HTTPS clone URL for this repository. The ops box clones it at boot to get
    the bring-up scripts. The repository is public, which is what lets the box
    hold no credentials of any kind — no GitHub token, no deploy key.
  EOT
  type        = string
  default     = "https://github.com/lago-morph/k8s-platform.git"
}

variable "repo_ref" {
  description = "Git ref the ops box checks out. Use a branch while iterating; main for a real bring-up."
  type        = string
  default     = "main"
}
