#!/usr/bin/env bash
# publish-vault.sh — publish a new version of a Forge vault to the registry.
#
# Tags + pushes the vault repo, fetches GitHub's auto-generated tarball,
# computes its SHA-256, updates forge-registry/index.json (adds the new
# version entry + bumps `latest`), commits + pushes the registry.
#
# Usage:
#   bash publish-vault.sh <vault-name>            # auto-patch bump
#   bash publish-vault.sh <vault-name> <version>  # explicit version
#   bash publish-vault.sh --all                   # auto-patch every registry vault;
#                                                 # skips vaults with no commits since last tag
#
# Requirements:
#   - Both the vault repo and forge-registry have clean working trees.
#   - `gh` CLI authenticated.
#   - `jq` installed.
#   - Vault repos live at ${PROJECTS_DIR}/<vault-name>/ (default ${HOME}/projects).
#
# Convention: every published version becomes `latest`. Non-latest backports
# require a manual edit of index.json.

set -euo pipefail

# Make sure brew-installed binaries are on PATH.
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/projects}"
REGISTRY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INDEX_JSON="${REGISTRY_DIR}/index.json"

# --- Tool checks ---
for cmd in git jq gh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $cmd"
    [ "$cmd" = "jq" ] && echo "  Install with: brew install jq"
    [ "$cmd" = "gh" ] && echo "  Install with: brew install gh && gh auth login"
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

if [ ! -f "$INDEX_JSON" ]; then
  echo "ERROR: registry index.json not found at $INDEX_JSON"
  exit 1
fi

# --- Helpers ---

# Reads the `version` value from a forge.toml.
read_vault_version() {
  local vault_dir="$1"
  grep -E '^version[[:space:]]*=' "${vault_dir}/forge.toml" \
    | head -1 | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/'
}

# Writes a new `version` value into the vault's forge.toml in place.
write_vault_version() {
  local vault_dir="$1"
  local new_version="$2"
  # Use a sed that's portable between macOS and GNU.
  if sed --version >/dev/null 2>&1; then
    sed -i -E "s/^version[[:space:]]*=.*$/version = \"${new_version}\"/" "${vault_dir}/forge.toml"
  else
    sed -i '' -E "s/^version[[:space:]]*=.*$/version = \"${new_version}\"/" "${vault_dir}/forge.toml"
  fi
}

# Bumps the patch component: 0.5.0 → 0.5.1.
bump_patch() {
  IFS='.' read -r major minor patch <<< "$1"
  echo "${major}.${minor}.$((patch + 1))"
}

# Returns the latest tag in a vault repo, or empty if no tags.
latest_tag() {
  local vault_dir="$1"
  (cd "$vault_dir" && git describe --tags --abbrev=0 2>/dev/null) || true
}

# Returns count of commits since the latest tag. 0 means no new commits.
commits_since_tag() {
  local vault_dir="$1"
  local tag="$2"
  (cd "$vault_dir" && git rev-list --count "HEAD" "^${tag}")
}

# Returns the list of vault names known to the registry (top-level keys
# under "vaults" in index.json).
registry_vaults() {
  jq -r '.vaults | keys[]' "$INDEX_JSON"
}

# Verifies a repo has no committed-but-unpushed commits on the current
# branch. Returns 0 if in sync (or no upstream — printed as a warning,
# not an error). Returns 1 if ahead of upstream.
check_unpushed() {
  local dir="$1"
  local repo_name="$2"
  local ahead
  if ! ahead=$(cd "$dir" && git rev-list --count '@{u}..HEAD' 2>/dev/null); then
    echo "WARNING: $repo_name has no upstream configured for the current branch."
    echo "  Run 'git push -u origin <branch>' first if you intend this repo to publish."
    return 1
  fi
  if [ "$ahead" -gt 0 ]; then
    echo "ERROR: $repo_name has $ahead unpushed commit(s) on the current branch."
    echo "  Push or remove them before publishing."
    return 1
  fi
}

# --- Publish one vault ---
# Args: vault-name [version]
# Returns 0 on success, non-zero on failure.
publish_one() {
  local vault_name="$1"
  local explicit_version="${2:-}"
  local vault_dir="${PROJECTS_DIR}/${vault_name}"

  echo
  echo "=== Publishing ${vault_name} ==="

  if [ ! -d "$vault_dir" ]; then
    echo "ERROR: vault directory not found: $vault_dir"
    return 1
  fi
  if [ ! -f "${vault_dir}/forge.toml" ]; then
    echo "ERROR: no forge.toml in $vault_dir"
    return 1
  fi

  # Clean working tree in the vault repo.
  local dirty
  dirty=$(cd "$vault_dir" && git status --porcelain)
  if [ -n "$dirty" ]; then
    echo "ERROR: $vault_dir has uncommitted changes:"
    echo "$dirty"
    return 1
  fi

  # Vault repo must be in sync with origin (no unpushed commits).
  if ! check_unpushed "$vault_dir" "$vault_name"; then
    return 1
  fi

  local current_version new_version
  current_version=$(read_vault_version "$vault_dir")
  if [ -z "$current_version" ]; then
    echo "ERROR: could not read version from ${vault_dir}/forge.toml"
    return 1
  fi
  echo "Current version: $current_version"

  if [ -n "$explicit_version" ]; then
    new_version="$explicit_version"
  else
    new_version=$(bump_patch "$current_version")
  fi
  echo "New version:     $new_version"

  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version '$new_version' is not semver (X.Y.Z)."
    return 1
  fi
  if [ "$new_version" = "$current_version" ]; then
    echo "ERROR: new version equals current ($current_version). Bump it."
    return 1
  fi

  # --- Bump forge.toml, commit, tag, push ---
  echo "Bumping ${vault_name}/forge.toml..."
  write_vault_version "$vault_dir" "$new_version"

  (
    cd "$vault_dir"
    git add forge.toml
    git commit -m "Release v${new_version}"
    git tag -a "v${new_version}" -m "Release v${new_version}"
    git push origin main
    git push origin "v${new_version}"
  )

  # --- Fetch tarball + compute sha256 ---
  local tarball_url="https://github.com/frmoded/${vault_name}/archive/refs/tags/v${new_version}.tar.gz"
  echo "Fetching tarball: $tarball_url"

  local sha256=""
  local attempts=0
  while [ $attempts -lt 5 ]; do
    sha256=$(curl -fsSL "$tarball_url" 2>/dev/null | shasum -a 256 | awk '{print $1}')
    if [ -n "$sha256" ] && [ ${#sha256} -eq 64 ]; then
      break
    fi
    sha256=""
    attempts=$((attempts + 1))
    echo "  Tarball not ready yet, retrying in 3s... (attempt $attempts/5)"
    sleep 3
  done

  if [ -z "$sha256" ]; then
    echo "ERROR: failed to fetch tarball after 5 attempts."
    echo "  Check that the tag pushed and the URL resolves:"
    echo "  $tarball_url"
    return 1
  fi
  echo "SHA-256: $sha256"

  # --- Update index.json ---
  echo "Updating registry index..."
  local tmp
  tmp=$(mktemp)
  jq --arg name "$vault_name" \
     --arg ver "$new_version" \
     --arg url "$tarball_url" \
     --arg sha "$sha256" \
     '.vaults[$name].versions[$ver] = {"tarball": $url, "sha256": $sha}
      | .vaults[$name].latest = $ver' \
     "$INDEX_JSON" > "$tmp" && mv "$tmp" "$INDEX_JSON"

  echo "Done with $vault_name."
}

# --- Main ---

# Mode dispatch
if [ $# -eq 0 ]; then
  echo "Usage:"
  echo "  bash publish-vault.sh <vault-name>            # auto-patch bump"
  echo "  bash publish-vault.sh <vault-name> <version>  # explicit version"
  echo "  bash publish-vault.sh --all                   # auto-patch every registry vault"
  exit 1
fi

# Registry working tree must be clean before we start.
REGISTRY_DIRTY=$(cd "$REGISTRY_DIR" && git status --porcelain)
if [ -n "$REGISTRY_DIRTY" ]; then
  echo "ERROR: $REGISTRY_DIR has uncommitted changes:"
  echo "$REGISTRY_DIRTY"
  echo "Commit or stash before publishing."
  exit 1
fi

# Registry must also be in sync with origin (no unpushed commits).
if ! check_unpushed "$REGISTRY_DIR" "forge-registry"; then
  exit 1
fi

if [ "$1" = "--all" ]; then
  echo "=== Publishing ALL registry vaults (auto-patch, skip-if-unchanged) ==="
  PUBLISHED=()
  SKIPPED=()
  FAILED=()

  while IFS= read -r vault_name; do
    vault_dir="${PROJECTS_DIR}/${vault_name}"
    if [ ! -d "$vault_dir" ]; then
      echo "SKIP $vault_name: directory not found at $vault_dir"
      SKIPPED+=("$vault_name (no local clone)")
      continue
    fi

    tag=$(latest_tag "$vault_dir")
    if [ -z "$tag" ]; then
      echo "$vault_name has no tags; will publish a fresh release."
    else
      n=$(commits_since_tag "$vault_dir" "$tag")
      if [ "$n" -eq 0 ]; then
        echo "SKIP $vault_name: no commits since $tag"
        SKIPPED+=("$vault_name (no changes since $tag)")
        continue
      fi
      echo "$vault_name has $n commits since $tag — will publish."
    fi

    if publish_one "$vault_name"; then
      PUBLISHED+=("$vault_name")
    else
      FAILED+=("$vault_name")
      echo "WARNING: $vault_name failed; continuing with other vaults."
    fi
  done < <(registry_vaults)

  # Commit registry changes if any were made.
  if [ ${#PUBLISHED[@]} -gt 0 ]; then
    echo
    echo "=== Committing registry updates ==="
    (
      cd "$REGISTRY_DIR"
      git add index.json
      git commit -m "Publish: ${PUBLISHED[*]}"
      git push
    )
  fi

  echo
  echo "=== Summary ==="
  [ ${#PUBLISHED[@]} -gt 0 ] && echo "Published: ${PUBLISHED[*]}"
  [ ${#SKIPPED[@]}   -gt 0 ] && printf "Skipped:   %s\n" "${SKIPPED[@]}"
  [ ${#FAILED[@]}    -gt 0 ] && echo "Failed:    ${FAILED[*]}" && exit 1
else
  # Single-vault mode.
  publish_one "$1" "${2:-}"

  # Commit + push the registry change.
  echo
  echo "=== Committing registry update ==="
  (
    cd "$REGISTRY_DIR"
    git add index.json
    git commit -m "Publish $1 v$(jq -r --arg n "$1" '.vaults[$n].latest' "$INDEX_JSON")"
    git push
  )
fi

echo
echo "=== Done ==="
