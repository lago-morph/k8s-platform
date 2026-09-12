# The ops box — the machine a person drives a bring-up from.
#
# WHY THIS EXISTS (owner direction 2026-09-10, bead kp-2al.34): the documented
# bring-up spanned the GitHub Actions UI, a terminal and a verification sweep
# the operator had to interpret by hand. Clicking the workflow buttons is fine;
# the interpretation is what had to go. This box is where the scripts that do
# the interpreting run.
#
# WHY NOT THE OPERATOR'S LAPTOP: that machine carries unrelated work
# credentials and must stay completely separate from this project. The box gets
# an IAM instance profile, so this project's credentials are issued by AWS to
# the instance and never exist as a file on any machine the operator touches.
# Reached through Session Manager in the AWS console — a browser shell — so
# there is no local `aws` CLI, no access key, no SSH key and no kubeconfig.
#
# WHY THE DEFAULT VPC: this box must predate `terraform/base` and outlive it.
# It has to be usable to WATCH the base build happen, and to survive the
# teardown that removes the platform VPC. Putting it in the platform's own VPC
# would make it die with every teardown and leave it unable to observe the
# thing that creates it.

locals {
  name = "k8-platform-opsbox"
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Not every AZ offers every instance type, and the default VPC has a subnet in
# ALL of them. Picking a subnet blindly put the first ops box in us-east-1e,
# where t3.small is not offered at all, and RunInstances refused it outright:
#   "Your requested instance type (t3.small) is not supported in your requested
#    Availability Zone (us-east-1e)"
# So ask which AZs actually offer this type, and only consider subnets there.
data "aws_ec2_instance_type_offerings" "opsbox" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  location_type = "availability-zone"
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# Amazon Linux 2023, resolved from the public SSM parameter so no AMI id is
# ever committed (they are region-specific and rotate).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

locals {
  # Default-VPC subnets that sit in an AZ where this instance type is offered.
  usable_subnet_ids = sort([
    for s in data.aws_subnet.default : s.id
    if contains(data.aws_ec2_instance_type_offerings.opsbox.locations, s.availability_zone)
  ])
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "opsbox" {
  # Fixed name on purpose: the bring-up scripts grant this principal access to
  # each cluster as it appears, and a predictable name is what lets them.
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  description        = "Ops box that drives platform bring-up (kp-2al.34)"
}

# Session Manager. This is what makes the browser shell work, and it is the
# ONLY inbound path — the security group opens nothing.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.opsbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "opsbox" {
  # Read the world. Every "is this stage green?" question the scripts ask is a
  # describe against AWS rather than a green checkmark on a CI run.
  statement {
    sid    = "ObserveTheAccount"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "cloudwatch:GetMetricData",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem", # the state lock item: held for exactly the duration of an apply
      "ec2:Describe*",
      "eks:Describe*",
      "eks:List*",
      "elasticloadbalancing:Describe*",
      "iam:GetRole",
      "iam:ListRoles",
      "logs:Describe*",
      "logs:GetLogEvents",
      "rds:Describe*",
      "route53:Get*",
      "route53:List*",
      "s3:GetBucketLocation",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  # Talk to the clusters, and grant this box access to each one as it appears.
  # The clusters do not exist when this module is applied, so the access entry
  # cannot be created here — the bring-up script creates it on first use.
  statement {
    sid    = "ReachTheClusters"
    effect = "Allow"
    actions = [
      "eks:AccessKubernetesApi",
      "eks:AssociateAccessPolicy",
      "eks:CreateAccessEntry",
      "eks:DescribeAccessEntry",
      "eks:ListAccessEntries",
      "eks:ListAssociatedAccessPolicies",
    ]
    resources = ["*"]
  }

  # The platform's own secrets namespace, for the Cognito bridge document the
  # directory-account step reads. Scoped to the platform's prefix.
  statement {
    sid    = "ReadPlatformSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = ["arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:k8-platform/*"]
  }

  # Creating an end-user directory account is a documented admin action
  # (docs/site/how-to/admin-access.md §4), so the box can perform it.
  statement {
    sid    = "AdministerTheDirectory"
    effect = "Allow"
    actions = [
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminListGroupsForUser",
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:GetGroup",
      "cognito-idp:ListUserPools",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "opsbox" {
  name   = local.name
  role   = aws_iam_role.opsbox.id
  policy = data.aws_iam_policy_document.opsbox.json
}

resource "aws_iam_instance_profile" "opsbox" {
  name = local.name
  role = aws_iam_role.opsbox.name
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# Egress only. Session Manager reaches the instance through the SSM agent's
# outbound connection, so nothing needs to be open inbound — there is no SSH
# port to leave exposed and no key to manage.
resource "aws_security_group" "opsbox" {
  name        = local.name
  description = "Ops box: egress only; inbound access is via SSM Session Manager"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (AWS APIs, EKS endpoints, GitHub, package mirrors)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_instance" "opsbox" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.usable_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.opsbox.name
  vpc_security_group_ids = [aws_security_group.opsbox.id]

  # A public IP so the box can reach GitHub and the package mirrors without a
  # NAT gateway. The default VPC's subnets are public; nothing listens here.
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url = var.repo_url
    repo_ref = var.repo_ref
  })

  # A clear failure rather than an index-out-of-range if the account offers
  # this type in no AZ at all.
  lifecycle {
    precondition {
      condition     = length(local.usable_subnet_ids) > 0
      error_message = "No default-VPC subnet sits in an AZ that offers ${var.instance_type}. Pick a different instance_type."
    }
  }

  tags = { Name = local.name }
}
