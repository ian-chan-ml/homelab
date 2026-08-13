#!/usr/bin/env bash
# onboard-ssh-keys.sh — Seed ~/.ssh/authorized_keys from a public Gist of pubkeys
#
# Public keys aren't secret, so this pulls from a plain public Gist —
# no auth token needed, works as a true one-line curl | bash.
#
# Setup (one-time):
#   1. Create a public GitHub Gist named `authorized_keys` containing your
#      phone's and any other trusted public keys, one per line.
#   2. Set KEYS_URL below to the Gist's raw URL.
#
# Usage (on any new machine):
#   curl -fsSL https://raw.githubusercontent.com/ian-cq/homelab/main/onboard-ssh-keys.sh | bash
#
# Adding a new key later: edit the Gist, re-run the one-liner on any machine.
# Existing keys are never duplicated.

set -euo pipefail

KEYS_URL="${KEYS_URL:-https://gist.githubusercontent.com/<user>/<gist_id>/raw/authorized_keys}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

curl -fsSL "$KEYS_URL" | while read -r line; do
  [ -z "$line" ] && continue
  grep -qxF "$line" ~/.ssh/authorized_keys || echo "$line" >> ~/.ssh/authorized_keys
done

echo "authorized_keys updated ($(wc -l < ~/.ssh/authorized_keys) keys)."
