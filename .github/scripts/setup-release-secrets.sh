#!/usr/bin/env bash
# One-shot loader for the GitHub repo secrets required by
# .github/workflows/runner-release.yml. Fill in the values below, then run:
#
#   bash .github/scripts/setup-runner-release-secrets.sh
#
# Re-run safely — `gh secret set` upserts. Requires `gh auth login` first with
# admin:repo scope.

set -euo pipefail

REPO="neverprepared/phantom-ink"

# ── 1. Developer ID Application certificate ─────────────────────────────────
# Apple Developer → Certificates → Developer ID Application → Create.
# Download the .cer, install into Keychain Access, right-click → Export as
# .p12 with a password. Then:
#   base64 -i /path/to/cert.p12 -o /tmp/cert.p12.b64
CERT_P12_B64_FILE=""             # e.g. /tmp/cert.p12.b64
CERT_P12_PASSWORD=""             # the password you set during the .p12 export

# Identity string as codesign sees it. Find it with:
#   security find-identity -v -p codesigning
# (paste the full quoted string, including the team ID in parens)
MACOS_IDENTITY=""                # e.g. "Developer ID Application: Foo Bar (ABCDE12345)"

# ── 2. Apple ID + notarization credentials ──────────────────────────────────
# Apple Developer → Membership → Team ID (10 chars, alphanumeric)
APPLE_TEAM_ID=""                 # e.g. ABCDE12345

# The Apple ID email you sign into developer.apple.com with
APPLE_ID=""                      # e.g. you@example.com

# https://appleid.apple.com/account/manage → Sign-In and Security →
# App-Specific Passwords → generate one for "notarytool"
APPLE_APP_PASSWORD=""            # format: xxxx-xxxx-xxxx-xxxx

# ── 3. CI keychain password (any random string) ─────────────────────────────
KEYCHAIN_PWD="$(openssl rand -hex 24)"

# ────────────────────────────────────────────────────────────────────────────

require() {
  local name=$1
  local val=$2
  if [ -z "$val" ]; then
    echo "error: $name is empty — fill it in at the top of this script" >&2
    exit 1
  fi
}

require CERT_P12_B64_FILE "$CERT_P12_B64_FILE"
require CERT_P12_PASSWORD "$CERT_P12_PASSWORD"
require MACOS_IDENTITY    "$MACOS_IDENTITY"
require APPLE_TEAM_ID     "$APPLE_TEAM_ID"
require APPLE_ID          "$APPLE_ID"
require APPLE_APP_PASSWORD "$APPLE_APP_PASSWORD"
require KEYCHAIN_PWD      "$KEYCHAIN_PWD"

if [ ! -f "$CERT_P12_B64_FILE" ]; then
  echo "error: CERT_P12_B64_FILE not found at $CERT_P12_B64_FILE" >&2
  exit 1
fi

echo "→ Setting secrets on $REPO"
gh secret set MACOS_CERTIFICATE      --repo "$REPO" < "$CERT_P12_B64_FILE"
gh secret set MACOS_CERTIFICATE_PWD  --repo "$REPO" --body "$CERT_P12_PASSWORD"
gh secret set MACOS_IDENTITY         --repo "$REPO" --body "$MACOS_IDENTITY"
gh secret set APPLE_TEAM_ID          --repo "$REPO" --body "$APPLE_TEAM_ID"
gh secret set APPLE_ID               --repo "$REPO" --body "$APPLE_ID"
gh secret set APPLE_APP_PASSWORD     --repo "$REPO" --body "$APPLE_APP_PASSWORD"
gh secret set KEYCHAIN_PWD           --repo "$REPO" --body "$KEYCHAIN_PWD"

echo "→ Verifying"
gh secret list --repo "$REPO"

echo
echo "Done. To re-run the release after secrets are set:"
echo "  git tag -d runner/v0.1.0 && \\"
echo "  git push https://github.com/$REPO.git --delete runner/v0.1.0 && \\"
echo "  git tag -a runner/v0.1.0 -m 'Brainbox Runner v0.1.0 (re-tag)' && \\"
echo "  git push https://github.com/$REPO.git runner/v0.1.0"
echo
echo "Or just bump the version (less destructive):"
echo "  git tag -a runner/v0.1.1 -m 'Brainbox Runner v0.1.1' && \\"
echo "  git push https://github.com/$REPO.git runner/v0.1.1"
