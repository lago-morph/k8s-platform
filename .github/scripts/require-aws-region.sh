#!/usr/bin/env bash
# Fail fast when the AWS_REGION repository variable is unset (kp-2al.36).
#
# Workflows take their region from `vars.AWS_REGION` (a repository VARIABLE),
# not a secret: GitHub masks every occurrence of a referenced secret's value in
# job logs, so a region held as a secret turned `us-east-1` into `***`
# everywhere — including the Ops box console URL, which became unusable.
#
# An unset variable expands to the empty string. Rather than letting the AWS
# CLI or Terraform pick some region silently (and build in, or look for state
# in, the wrong place), the job stops here with a message naming the fix.
#
# Usage (as a workflow step, with AWS_DEFAULT_REGION: ${{ vars.AWS_REGION }}):
#   .github/scripts/require-aws-region.sh
set -euo pipefail

region="${AWS_DEFAULT_REGION:-}"

if [ -z "$region" ]; then
  msg="The AWS_REGION repository variable is not set. Create it under Settings -> Secrets and variables -> Actions -> Variables (e.g. us-east-1). It is a variable, not a secret: a secret would be masked as *** in every log line, console URLs included."
  echo "::error title=AWS_REGION repository variable not set::${msg}"
  echo "$msg" >&2
  exit 1
fi

# A region is lowercase letters, digits and hyphens (us-east-1, eu-west-2,
# us-gov-west-1). Anything else is a typo that would fail later, obscurely.
if ! printf '%s' "$region" | grep -Eq '^[a-z]{2}(-[a-z]+)+-[0-9]+$'; then
  msg="The AWS_REGION repository variable is '${region}', which is not an AWS region name (expected e.g. us-east-1). Fix it under Settings -> Secrets and variables -> Actions -> Variables."
  echo "::error title=AWS_REGION repository variable malformed::${msg}"
  echo "$msg" >&2
  exit 1
fi

echo "AWS region: ${region} (from the AWS_REGION repository variable)"
