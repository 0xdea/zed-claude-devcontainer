#!/usr/bin/env bash
set -euo pipefail

# Claude Code Devcontainer CLI Helper
# Provides the `devc` command for managing devcontainers

# Resolve symlinks to get actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
# From SOURCE, not $0: via the installed devc symlink $0 is "devc"
SCRIPT_NAME="$(basename "$SOURCE")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<EOF
Usage: devc <command> [options]

Commands:
    .                                 Install devcontainer template to current directory and start
    up                                Start the devcontainer in current directory
    rebuild [--no-cache]              Rebuild the devcontainer (preserves auth volumes)
    down                              Stop the devcontainer
    net lock|unlock|status [dir]      Limit outbound access to an allowlist, or lift it
    shell                             Open a shell in the running container
    self-install                      Install 'devc' command to ~/.local/bin
    update                            Update devc to the latest version
    template [dir]                    Copy devcontainer template to directory (default: current)
    exec <cmd>                        Execute a command in the running container
    upgrade                           Upgrade Claude Code on its update channel
    mount <host> <cont> [--readonly]  Add a mount to the devcontainer (recreates container)
    sync [project] [--trusted]        Sync sessions from devcontainers to host
    cp <cont> <host>                  Copy files/directories from container to host
    destroy [-f]                      Remove container, volumes, and image for current project
    help                              Show this help message

Examples:
    devc .                            # Install template and start container
    devc up                           # Start container in current directory
    devc rebuild                      # Clean rebuild
    devc rebuild --no-cache           # Rebuild without Docker's cache (refreshes tools)
    devc net lock                     # Allow only Claude, GitHub, registries, and net-allow
    devc shell                        # Open interactive shell
    devc self-install                 # Install devc to PATH
    devc update                       # Update to latest version
    devc exec ls -la                  # Run command in container
    devc upgrade                      # Upgrade Claude Code
    devc mount ~/data /data           # Add mount to container
    devc mount ~/ref /ref --readonly  # Add read-only mount (--readonly goes last)
    devc sync                         # Sync sessions from all devcontainers
    devc sync crypto                  # Sync only matching devcontainer
    devc cp /some/file ./out          # Copy a path from container to host
    devc destroy                      # Remove all project Docker resources
    devc destroy -f                   # Skip confirmation prompt
EOF
}

log_info() {
  echo -e "${BLUE}[devc]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[devc]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[devc]${NC} $1"
}

log_error() {
  echo -e "${RED}[devc]${NC} $1" >&2
}

check_devcontainer_cli() {
  if ! command -v devcontainer &>/dev/null; then
    log_error "devcontainer CLI not found."
    log_info "Install it with: npm install -g @devcontainers/cli"
    exit 1
  fi
}

# jq failures are mostly ignored below (e.g., strip_git_mounts_if_not_repo then
# leaves the file alone), so a missing jq would silently skip steps and drop mounts.
check_jq() {
  if ! command -v jq &>/dev/null; then
    log_error "jq not found."
    log_info "Install it with your package manager, e.g.: brew install jq"
    exit 1
  fi
}

# Docker accepts capability names in any case, with or without the CAP_ prefix,
# and ALL and privileged mode include SYS_ADMIN.
CAPABILITY_JQ='
  def cap_name: ascii_upcase | ltrimstr("CAP_");
  def grants_sys_admin: cap_name | (. == "SYS_ADMIN" or . == "ALL");'

# Reads the configuration through the devcontainer CLI, which finds and parses it
# (JSONC included) like `devcontainer up` does, and resolves the features it lists
# (e.g., docker-in-docker requests privileged mode), so this runs before anything
# starts. Only the current file and its features are checked: privileges from image
# metadata only exist after the build, so devcontainer_up checks the container
# itself. Resolving features needs the network; without it, the file is still
# checked and the features are left to devcontainer_up.
check_no_sys_admin() {
  local workspace="${1:-.}"
  local config found
  if ! config=$(devcontainer read-configuration --include-features-configuration \
    --workspace-folder "$workspace" 2>/dev/null); then
    if ! config=$(devcontainer read-configuration --workspace-folder "$workspace" 2>/dev/null); then
      log_error "Could not find or read a devcontainer configuration in $workspace."
      exit 1
    fi
    log_warn "Could not resolve the features (offline, or a feature can't be found):"
    log_warn "their privileges are only checked once the container has started."
  fi
  if ! found=$(jq -r "$CAPABILITY_JQ"'
    [
      (.configuration | objects | (
        (select(.privileged == true) | "\"privileged\": true"),
        (.capAdd[]? | strings | select(grants_sys_admin) | "\"capAdd\": \(.)"),
        ((.runArgs // []) as $args | range($args | length) as $i
          | ($args[$i] | strings) as $arg
          | select(
              ($arg | test("SYS_ADMIN"; "i")) or
              ($arg | test("^--privileged(=(1|t|true))?$"; "i")) or
              ($arg | test("^--cap-add=") and
                ($arg | ltrimstr("--cap-add=") | grants_sys_admin)) or
              ($arg == "--cap-add" and
                ($args[$i + 1] // "" | strings | grants_sys_admin))
            )
          | "runArgs: \($arg)\(if $arg == "--cap-add" then " \($args[$i + 1])" else "" end)")
      )),
      (.featuresConfiguration.featureSets[]?.features[]? | (
        (select(.privileged == true) | "feature \(.id): \"privileged\": true"),
        (.capAdd[]? | strings | select(grants_sys_admin) | "feature \(.id): \"capAdd\": \(.)")
      ))
    ] | first // empty
  ' <<<"$config"); then
    log_error "Could not check the devcontainer configuration for SYS_ADMIN."
    exit 1
  fi
  if [[ -n "$found" ]]; then
    log_error "SYS_ADMIN capability or privileged mode requested ($found)."
    log_error "This defeats the read-only .devcontainer mount."
    exit 1
  fi
}

# Always the absolute path with symlinks resolved: containers are found by
# their devcontainer.local_folder label, which must match the path they were
# created with ("devc ." passes ".", which the CLI resolves to the real path).
get_workspace_folder() {
  local dir="${1:-.}"
  (CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || {
    log_error "Directory does not exist: $dir"
    exit 1
  }
}

# Docker rejects a bind mount whose source is missing, so the .git mounts break
# container creation in a non-repo workspace. `devc template` restores them.
strip_git_mounts_if_not_repo() {
  local devcontainer_json="$1"
  local workspace="$2"

  [[ -f "$devcontainer_json" ]] || return 0
  [[ -f "$workspace/.git/config" && -d "$workspace/.git/hooks" ]] && return 0

  local updated
  updated=$(jq '
    .mounts = ((.mounts // []) | map(select(
      test("target=/workspaces/[^/,]+/\\.git/(config|hooks)") | not
    )))
  ' "$devcontainer_json") || return 0

  [[ "$updated" == "$(cat "$devcontainer_json")" ]] && return 0

  echo "$updated" >"$devcontainer_json"
  log_warn "Workspace is not a git repository - removed the read-only .git mounts."
  log_info "After 'git init', re-run 'devc template' to restore them."
}

# Extract custom mounts from devcontainer.json to a temp file
# Returns the temp file path, or empty string if no custom mounts
#
# Security: .devcontainer/ is mounted read-only inside the container to prevent
# a compromised process from injecting malicious mounts or commands into
# devcontainer.json that execute on the host during rebuild. This protection
# requires that the container never gets SYS_ADMIN (directly, via ALL, or via
# privileged mode), which would allow remounting read-write.
extract_mounts_to_file() {
  local devcontainer_json="$1"
  local temp_file

  [[ -f "$devcontainer_json" ]] || return 0

  temp_file=$(mktemp)

  # Filter out default mounts by target path (immune to project name changes)
  local custom_mounts
  custom_mounts=$(jq -c '
    .mounts // [] | map(
      select(
        (contains("target=/commandhistory,") | not) and
        (contains("target=/home/vscode/.claude,") | not) and
        (contains("target=/home/vscode/.config/gh,") | not) and
        (contains("target=/home/vscode/.gitconfig,") | not) and
        (test("target=/workspaces/[^/,]+/\\.devcontainer,") | not) and
        (test("target=/workspaces/[^/,]+/\\.git/(config|hooks),") | not)
      )
    ) | if length > 0 then . else empty end
  ' "$devcontainer_json" 2>/dev/null) || true

  if [[ -n "$custom_mounts" ]]; then
    echo "$custom_mounts" >"$temp_file"
    echo "$temp_file"
  else
    rm -f "$temp_file"
  fi
}

# Merge preserved mounts back into devcontainer.json
merge_mounts_from_file() {
  local devcontainer_json="$1"
  local mounts_file="$2"

  [[ -f "$mounts_file" ]] || return 0
  [[ -s "$mounts_file" ]] || return 0

  local custom_mounts
  custom_mounts=$(cat "$mounts_file")

  local updated
  updated=$(jq --argjson custom "$custom_mounts" '
    .mounts = ((.mounts // []) + $custom | unique)
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Add or update a mount in devcontainer.json
update_devcontainer_mounts() {
  local devcontainer_json="$1"
  local host_path="$2"
  local container_path="$3"
  local readonly="${4:-false}"

  local mount_str="source=${host_path},target=${container_path},type=bind"
  [[ "$readonly" == "true" ]] && mount_str="${mount_str},readonly"

  local updated
  updated=$(jq --arg target "$container_path" --arg mount "$mount_str" '
    .mounts = (
      ((.mounts // []) | map(select(contains("target=" + $target + ",") or endswith("target=" + $target) | not)))
      + [$mount]
    )
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

cmd_template() {
  check_jq

  local target_dir="${1:-.}"
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    log_error "Directory does not exist: $1"
    exit 1
  }

  local devcontainer_dir="$target_dir/.devcontainer"
  local devcontainer_json="$devcontainer_dir/devcontainer.json"
  local preserved_mounts="" keep_net_raw=false

  if [[ -d "$devcontainer_dir" ]]; then
    log_warn "Devcontainer already exists at $devcontainer_dir"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Preserve custom mounts before overwriting
    preserved_mounts=$(extract_mounts_to_file "$devcontainer_json")
    if [[ -n "$preserved_mounts" ]]; then
      log_info "Preserving custom mounts..."
    fi
    # The raw sockets opt-in (see the README's "Raw sockets"). Older templates had NET_RAW
    # by default, always with NET_ADMIN, which isn't an opt-in
    if jq -e '(.runArgs // []) | index("--cap-add=NET_RAW") and (index("--cap-add=NET_ADMIN") | not)' \
      "$devcontainer_json" >/dev/null 2>&1; then
      keep_net_raw=true
    fi
  fi

  mkdir -p "$devcontainer_dir"

  # Copy template files
  cp "$SCRIPT_DIR/Dockerfile" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/devcontainer.json" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/post_install.py" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/.zshrc" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/devcontainer.fish" "$devcontainer_dir/"

  # Restore preserved mounts
  if [[ -n "$preserved_mounts" ]]; then
    merge_mounts_from_file "$devcontainer_json" "$preserved_mounts"
    rm -f "$preserved_mounts"
    log_info "Custom mounts restored"
  fi

  if [[ "$keep_net_raw" == true ]]; then
    local updated
    updated=$(jq '.runArgs |= map(if . == "--cap-drop=NET_RAW" then "--cap-add=NET_RAW" else . end)' \
      "$devcontainer_json")
    echo "$updated" >"$devcontainer_json"
    log_info "Kept --cap-add=NET_RAW (raw sockets)"
  fi

  strip_git_mounts_if_not_repo "$devcontainer_json" "$target_dir"

  log_success "Template installed to $devcontainer_dir"
}

# Run `devcontainer up`, then check the privileges Docker actually granted: the
# image's metadata can request privileged mode or capabilities that
# check_no_sys_admin can't see before the image is built. Fails closed: a
# container it can't inspect is stopped.
devcontainer_up() {
  local result container_id host_config found status=0
  # The CLI logs to stderr and prints a JSON result on stdout, also when it fails after
  # creating the container (e.g., a failing postCreateCommand), so check the container
  # before passing the failure on
  result=$(devcontainer up "$@") || status=$?
  [[ -n "$result" ]] && printf '%s\n' "$result"
  container_id=$(jq -r '.containerId // empty' <<<"$result" 2>/dev/null) || true
  if [[ -z "$container_id" ]]; then
    if [[ "$status" -eq 0 ]]; then
      log_error "devcontainer up returned no container ID, so its privileges can't be checked."
      exit 1
    fi
    return "$status"
  fi

  if ! host_config=$(docker inspect --format '{{json .HostConfig}}' "$container_id") ||
    ! found=$(jq -r "$CAPABILITY_JQ"'
      [
        (select(.Privileged == true) | "privileged mode"),
        (.CapAdd[]? | strings | select(grants_sys_admin) | "capability \(.)")
      ] | first // empty
    ' <<<"$host_config"); then
    if docker stop "$container_id" >/dev/null; then
      log_error "Could not check the container's privileges, so it was stopped."
    else
      log_error "Could not check the container's privileges, nor stop it."
      log_error "It may still be running: docker stop $container_id"
    fi
    exit 1
  fi
  if [[ -n "$found" ]]; then
    if docker stop "$container_id" >/dev/null; then
      log_error "The container was started with $found, so it was stopped."
    else
      log_error "The container was started with $found, and stopping it failed."
      log_error "It may still be running: docker stop $container_id"
    fi
    log_error "This defeats the read-only .devcontainer mount. If devcontainer.json"
    log_error "doesn't request it, a feature or the image does."
    exit 1
  fi
  return "$status"
}

# The template reads DEVC_DOTFILES_REPO from the host when it builds the image, so say
# when it's unset, since an image built then has no dotfiles (only in the commands that
# build: devc . and devc rebuild)
note_dotfiles() {
  local devcontainer_json="$1/.devcontainer/devcontainer.json"
  if [[ -z "${DEVC_DOTFILES_REPO:-}" ]] &&
    grep -qF 'DEVC_DOTFILES_REPO' "$devcontainer_json" 2>/dev/null; then
    log_info "DEVC_DOTFILES_REPO isn't set: an image built now has no dotfiles (see the README's Dotfiles section)."
  fi
}

cmd_up() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_jq
  check_no_sys_admin "$workspace_folder"
  strip_git_mounts_if_not_repo \
    "$workspace_folder/.devcontainer/devcontainer.json" "$workspace_folder"
  log_info "Starting devcontainer in $workspace_folder..."

  devcontainer_up --workspace-folder "$workspace_folder"
  log_success "Devcontainer started"
}

cmd_rebuild() {
  local no_cache=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-cache)
        no_cache=true
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_jq
  check_no_sys_admin "$workspace_folder"
  strip_git_mounts_if_not_repo \
    "$workspace_folder/.devcontainer/devcontainer.json" "$workspace_folder"
  note_dotfiles "$workspace_folder"

  # Docker reuses cached layers, so steps that install the latest version of a
  # tool (Claude Code, Rust, dotfiles, ...) only rerun without the cache
  local up_args=(--workspace-folder "$workspace_folder" --remove-existing-container)
  if [[ "$no_cache" == true ]]; then
    up_args+=(--build-no-cache)
    log_info "Rebuilding devcontainer in $workspace_folder without the build cache..."
  else
    log_info "Rebuilding devcontainer in $workspace_folder..."
  fi

  devcontainer_up "${up_args[@]}"
  log_success "Devcontainer rebuilt"
}

cmd_down() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Stopping devcontainer..."

  # Get container ID and stop it
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -n "$container_id" ]]; then
    docker stop "$container_id"
    log_success "Devcontainer stopped"
  else
    log_warn "No running devcontainer found for $workspace_folder"
  fi
}

# Hosts that `devc net lock` always allows: Claude Code (API, sign-in and token refresh,
# updates), Zed's agent registry (installing and updating Zed's Claude agent, which
# downloads from GitHub releases), GitHub, and the Rust, npm, and PyPI registries. Anthropic and GitHub also
# publish their address ranges (NET_ALLOW_NETS), which don't change like resolved
# addresses: GitHub moves its hosts between addresses in these ranges. GitHub's are the
# ones its meta API (`gh api meta`) lists for web, api, and git, without the single
# regional addresses, which resolving the hosts covers.
NET_ALLOW_HOSTS=(
  api.anthropic.com claude.ai platform.claude.com downloads.claude.ai
  cdn.agentclientprotocol.com
  github.com api.github.com codeload.github.com objects.githubusercontent.com
  raw.githubusercontent.com release-assets.githubusercontent.com
  static.rust-lang.org crates.io index.crates.io static.crates.io
  registry.npmjs.org pypi.org files.pythonhosted.org
)
NET_ALLOW_NETS=(
  160.79.104.0/23 153.61.224.0/22
  140.82.112.0/20 143.55.64.0/20 185.199.108.0/22 192.30.252.0/22
)

# Runs in a fresh container on Docker's default network, not in the dev container's:
# that one shares /etc/hosts and /etc/resolv.conf with the dev container, where root
# could edit them to get its own addresses allowed. Prints "dns <ip>" for each IPv4
# nameserver, then "ip <ip>" for each address of the hosts given, or "fail <host>".
# cmd_net gives it the DNS servers set for the dev container itself (--dns), so that
# both use the same servers.
# shellcheck disable=SC2016 # expanded by the container's bash
NET_RESOLVE_SCRIPT='
set -uo pipefail
awk '\''$1 == "nameserver" && $2 ~ /^[0-9.]+$/ { print "dns " $2 }'\'' /etc/resolv.conf
for host in "$@"; do
  ips=$(getent ahostsv4 "$host" | awk '\''{ print $1 }'\'' | sort -u)
  if [[ -z "$ips" ]]; then
    echo "fail $host"
  else
    printf "ip %s\n" $ips
  fi
done
'

# Runs as root with NET_ADMIN in a helper container that shares the dev container's
# network namespace. Arguments: lock, unlock, or status; for lock, then "dns:<ip>" and
# "<ip or CIDR>" entries. The rules live in an "inet devc" table, replaced in one
# transaction. They see every packet because the container has no NET_RAW: raw sockets
# (AF_PACKET, AF_XDP) send through kernel paths that skip them. They don't accept
# established connections, so that connections opened before locking stop too.
# Exits with 100 if the image has no nft (nft uses 1 to 3 itself).
# shellcheck disable=SC2016 # expanded by the container's bash
NET_APPLY_SCRIPT='
set -euo pipefail
command -v nft >/dev/null || exit 100
action=$1
shift
drop_table="table inet devc
delete table inet devc"
set_def() {
  local name=$1
  shift
  echo "  set $name { type ipv4_addr; flags interval; auto-merge;"
  if [[ $# -gt 0 ]]; then
    local IFS=,
    echo "    elements = { $* }"
  fi
  echo "  }"
}
case "$action" in
lock)
  dns=()
  nets=()
  for entry in "$@"; do
    case "$entry" in
    dns:*) dns+=("${entry#dns:}") ;;
    *) nets+=("$entry") ;;
    esac
  done
  nft -f - <<EOF
$drop_table
table inet devc {
$(set_def dns "${dns[@]}")
$(set_def allowed "${nets[@]}")
  chain output {
    type filter hook output priority filter; policy drop;
    oifname "lo" accept
    ip daddr @dns udp dport 53 accept
    ip daddr @dns tcp dport 53 accept
    ip daddr @allowed accept
    meta l4proto tcp reject with tcp reset
    reject with icmpx admin-prohibited
  }
}
EOF
  ;;
unlock)
  nft -f - <<<"$drop_table"
  ;;
status)
  if nft list table inet devc >/dev/null 2>&1; then
    echo locked
  else
    echo unlocked
  fi
  ;;
esac
'

# From `docker inspect` of the container, two lines: its privileges that let code in it
# change the rules, comma-separated; then "raw" if it has NET_RAW (Docker grants it
# unless dropped), which lets code get around them.
NET_BYPASS_JQ="$CAPABILITY_JQ"'
  ([.HostConfig.CapAdd[]? | strings | cap_name
    | select(. == "NET_ADMIN" or grants_sys_admin)]
  + (if .HostConfig.Privileged == true then ["privileged mode"] else [] end)
  | join(", ")),
  (if ([.HostConfig.CapAdd[]? | strings | cap_name | select(. == "NET_RAW")] | length > 0)
      or ([.HostConfig.CapDrop[]? | strings | cap_name | select(. == "NET_RAW" or . == "ALL")] | length == 0)
    then "raw" else "" end)'

# Reads .devcontainer/net-allow: one hostname, IPv4 address, or IPv4 CIDR per line,
# with # comments. Prints "host <name>" or "net <address>" lines. Addresses must be
# exact, since nft would look up anything else as a hostname, with the dev container's
# /etc/hosts; hostnames that don't resolve get a warning.
read_net_allow() {
  local file="$1" line lineno=0
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  local ipv4="^$octet(\\.$octet){3}(/(3[0-2]|[12]?[0-9]))?\$"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then
      continue
    elif [[ "$line" =~ $ipv4 ]]; then
      echo "net $line"
    elif [[ "$line" =~ ^[0-9./]+$ ]]; then
      log_error "$file:$lineno: not an IPv4 address or CIDR: $line"
      return 1
    elif [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "host ${line%.}"
    else
      log_error "$file:$lineno: not a hostname, IPv4 address, or IPv4 CIDR: $line"
      return 1
    fi
  done <"$file"
}

# Locks or unlocks outbound access for a running devcontainer, or shows its state.
# See the README's "Network isolation" section.
cmd_net() {
  local action="${1:-status}"
  [[ $# -gt 0 ]] && shift
  case "$action" in
  lock | unlock | status) ;;
  *)
    log_error "Usage: devc net lock|unlock|status [dir]"
    exit 1
    ;;
  esac

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"
  check_jq

  local container_ids
  container_ids=$(docker ps -q --filter "label=devcontainer.local_folder=$workspace_folder")
  if [[ -z "$container_ids" ]]; then
    log_error "No running devcontainer found for $workspace_folder (start it with devc up)"
    exit 1
  elif [[ "$container_ids" == *$'\n'* ]]; then
    log_error "More than one running devcontainer found for $workspace_folder"
    exit 1
  fi
  local container_id="$container_ids"
  local inspect image network_mode privileges net_raw
  inspect=$(docker inspect --format '{{json .}}' "$container_id")
  image=$(jq -r '.Image' <<<"$inspect")
  network_mode=$(jq -r '.HostConfig.NetworkMode' <<<"$inspect")
  { read -r privileges; read -r net_raw; } < <(jq -r "$NET_BYPASS_JQ" <<<"$inspect")

  # The rules go into the container's network namespace, which with these modes is
  # the host's, another container's, or has no interfaces to filter
  case "$network_mode" in
  host | none | container:*)
    log_error "The container uses --network=$network_mode: devc net needs a network of its own."
    exit 1
    ;;
  esac

  local entries=() file_entries=""
  if [[ "$action" == lock ]]; then
    local hosts=("${NET_ALLOW_HOSTS[@]}") nets=("${NET_ALLOW_NETS[@]}")
    local allow_file="$workspace_folder/.devcontainer/net-allow" kind value
    # A symlink could point into the workspace, where code in the container can write
    if [[ -L "$allow_file" ]]; then
      log_error "$allow_file is a symlink: make it a regular file."
      exit 1
    elif [[ -f "$allow_file" ]]; then
      local parsed
      parsed=$(read_net_allow "$allow_file") || exit 1
      while read -r kind value; do
        case "$kind" in
        host) hosts+=("$value") ;;
        net) nets+=("$value") ;;
        *) continue ;;
        esac
        # Listed after locking, since a repository can ship its own net-allow
        file_entries+="${file_entries:+, }$value"
      done <<<"$parsed"
    fi

    # DNS servers set for the container (e.g., --dns in runArgs). They come from
    # Docker, so code in the container can't change them.
    local dns_args=() dns_server
    while read -r dns_server; do
      if [[ -n "$dns_server" ]]; then
        dns_args+=(--dns "$dns_server")
      fi
    done < <(jq -r '.HostConfig.Dns[]?' <<<"$inspect")

    local resolved
    resolved=$(docker run --rm -i --pull never --log-driver none --cap-drop ALL \
      ${dns_args[@]+"${dns_args[@]}"} --user 65534:65534 --entrypoint bash "$image" -s -- "${hosts[@]}" \
      <<<"$NET_RESOLVE_SCRIPT") || {
      log_error "Resolving the allowed hosts failed"
      exit 1
    }
    while read -r kind value; do
      case "$kind" in
      dns) entries+=("dns:$value") ;;
      ip) entries+=("$value") ;;
      fail) log_warn "$value doesn't resolve, so it isn't allowed" ;;
      esac
    done <<<"$resolved"
    if [[ "$resolved" != *"dns "* ]]; then
      log_warn "No IPv4 DNS server found for the container, so name lookups will fail while locked."
    fi
    entries+=("${nets[@]}")
  fi

  # stdout carries status's result; nft's errors go to stderr
  local output status=0
  output=$(docker run --rm -i --pull never --log-driver none --cap-drop ALL \
    --cap-add NET_ADMIN --network "container:$container_id" --user root \
    --entrypoint bash "$image" -s -- "$action" ${entries[@]+"${entries[@]}"} \
    <<<"$NET_APPLY_SCRIPT") || status=$?
  if [[ $status -eq 100 ]]; then
    log_error "The container's image has no nft. Rebuild it with the current template: devc template ., then devc rebuild."
    exit 1
  elif [[ $status -ne 0 ]]; then
    log_error "Changing the rules failed (see the error above), so nothing changed."
    exit 1
  fi

  local bypass_warning=""
  if [[ -n "$privileges" ]]; then
    bypass_warning="code in the container can undo it, since it has $privileges. Recreate it with the current template: devc template ., then devc rebuild."
  elif [[ "$net_raw" == raw ]]; then
    bypass_warning="code in the container can get around it with raw sockets, since it has NET_RAW (see Raw sockets in the README)."
  fi
  case "$action" in
  lock)
    if [[ -n "$bypass_warning" ]]; then
      log_warn "Network locked, but $bypass_warning"
    else
      log_success "Network locked: only the allowed hosts and DNS are reachable."
    fi
    if [[ -n "$file_entries" ]]; then
      log_info "Entries from .devcontainer/net-allow: $file_entries"
    fi
    log_info "It lasts until the container stops; run devc net lock again to refresh addresses."
    ;;
  unlock)
    log_success "Network unlocked: outbound access is unrestricted."
    ;;
  status)
    if [[ "$output" == unlocked ]]; then
      log_info "Network is unlocked: outbound access is unrestricted."
    elif [[ "$output" == locked ]]; then
      log_info "Network is locked: only the allowed hosts and DNS are reachable."
      if [[ -n "$bypass_warning" ]]; then
        log_warn "But $bypass_warning"
      fi
    else
      log_error "Checking the rules gave an unexpected result: $output"
      exit 1
    fi
    ;;
  esac
}

cmd_shell() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Opening shell in devcontainer..."

  devcontainer exec --workspace-folder "$workspace_folder" fish
}

cmd_exec() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  devcontainer exec --workspace-folder "$workspace_folder" "$@"
}

cmd_upgrade() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Upgrading Claude Code..."

  devcontainer exec --workspace-folder "$workspace_folder" claude update

  log_success "Claude Code upgraded"
}

cmd_mount() {
  local host_path="${1:-}"
  local container_path="${2:-}"
  local readonly="false"

  if [[ -z "$host_path" ]] || [[ -z "$container_path" ]]; then
    log_error "Usage: devc mount <host_path> <container_path> [--readonly]"
    exit 1
  fi

  [[ "${3:-}" == "--readonly" ]] && readonly="true"

  # Expand and validate host path
  host_path="$(cd "$host_path" 2>/dev/null && pwd)" || {
    log_error "Host path does not exist: $1"
    exit 1
  }

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'devc template' first."
    exit 1
  fi

  check_devcontainer_cli
  check_jq
  check_no_sys_admin "$workspace_folder"

  log_info "Adding mount: $host_path → $container_path"
  update_devcontainer_mounts "$devcontainer_json" "$host_path" "$container_path" "$readonly"
  strip_git_mounts_if_not_repo "$devcontainer_json" "$workspace_folder"

  log_info "Recreating container with new mount..."
  devcontainer_up --workspace-folder "$workspace_folder" --remove-existing-container

  log_success "Mount added: $host_path → $container_path"
}

cmd_sync() {
  local filter=""
  local trusted=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --trusted)
      trusted=true
      shift
      ;;
    *)
      filter="$1"
      shift
      ;;
    esac
  done

  local host_projects="${HOME}/.claude/projects"

  if [[ "$trusted" == false ]]; then
    log_warn "This copies files from devcontainers to your host filesystem."
    log_warn "Only proceed if you trust the container contents."
    log_info "Use --trusted to skip this prompt."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  # Discover all devcontainers (running + stopped) by label.
  local container_ids
  container_ids=$(docker ps -a -q \
    --filter "label=devcontainer.local_folder" 2>/dev/null || true)

  if [[ -z "$container_ids" ]]; then
    log_error "No devcontainers found (running or stopped)."
    exit 1
  fi

  # List discovered devcontainers.
  log_info "Discovered devcontainers:"
  local matched_any=false
  while IFS= read -r cid; do
    local name folder status
    name=$(sync_get_project_name "$cid")
    folder=$(docker inspect --format \
      '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
    status=$(docker inspect --format '{{.State.Status}}' "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    matched_any=true
    echo "  - ${name} (${status}) ${folder}"
  done <<< "$container_ids"

  if [[ "$matched_any" == false ]]; then
    log_error "No devcontainers matching '${filter}'."
    echo ""
    echo "Available:"
    while IFS= read -r cid; do
      local name status
      name=$(sync_get_project_name "$cid")
      status=$(docker inspect --format '{{.State.Status}}' "$cid")
      echo "  - ${name} (${status})"
    done <<< "$container_ids"
    exit 1
  fi

  echo ""

  # Sync matching containers.
  while IFS= read -r cid; do
    local name
    name=$(sync_get_project_name "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    sync_one_container "$cid" "$host_projects"
    echo ""
  done <<< "$container_ids"

  log_success "Run '/insights' in Claude Code to include these sessions."
}

# Extract project name from devcontainer.local_folder label.
sync_get_project_name() {
  local folder
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$1")
  basename "$folder"
}

# Resolve the Claude projects dir inside a container without
# docker exec (works on stopped containers too).
# Reads CLAUDE_CONFIG_DIR from container env, falls back to
# /home/<user>/.claude.
sync_get_claude_projects_dir() {
  local cid="$1"
  local claude_dir

  claude_dir=$(docker inspect --format '{{json .Config.Env}}' "$cid" \
    | tr ',' '\n' | tr -d '[]"' \
    | grep '^CLAUDE_CONFIG_DIR=' \
    | cut -d= -f2- || true)

  if [[ -n "$claude_dir" ]]; then
    echo "${claude_dir}/projects"
    return
  fi

  local user
  user=$(docker inspect --format '{{.Config.User}}' "$cid")
  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "/root/.claude/projects"
  else
    echo "/home/${user}/.claude/projects"
  fi
}

sync_one_container() {
  local cid="$1"
  local host_projects="$2"
  local project_name status claude_dir folder

  project_name=$(sync_get_project_name "$cid")
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
  status=$(docker inspect --format '{{.State.Status}}' "$cid")
  claude_dir=$(sync_get_claude_projects_dir "$cid")

  log_info "=== ${project_name} (${status}) ==="
  echo "  Host path:  ${folder}"
  echo "  Container:  ${cid:0:12}"

  # docker cp works on both running and stopped containers.
  local tmpdir
  tmpdir=$(mktemp -d)

  if ! docker cp "${cid}:${claude_dir}/." "$tmpdir/" 2>/dev/null; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  local session_count
  session_count=$(find "$tmpdir" -name '*.jsonl' | wc -l | tr -d ' ')

  if [[ "$session_count" -eq 0 ]]; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  echo "  Sessions:   ${session_count}"

  local total_copied=0

  # Claude Code keys projects by cwd with every non-alphanumeric char as '-'.
  # The workspace is /workspaces/<name> (older templates: /workspace).
  local ws_key
  ws_key=$(printf '%s' "/workspaces/${project_name}" | sed 's/[^A-Za-z0-9]/-/g')

  # Sync each project key subdirectory.
  for key_path in "$tmpdir"/*/; do
    [[ ! -d "$key_path" ]] && continue
    # Does not follow symlinks
    [[ -L "${key_path%/}" ]] && continue
    local key dest_key
    key=$(basename "$key_path")

    # Map /workspaces/<name> keys onto the old /workspace ones, so sessions
    # from containers before and after the move land in the same host dirs.
    if [[ "$key" == "$ws_key" || "$key" == "$ws_key"-* ]]; then
      key="-workspace${key#"$ws_key"}"
    fi

    # Always namespace under -devcontainer-<project>.
    if [[ "$key" == "-workspace" ]]; then
      dest_key="-devcontainer-${project_name}"
    else
      dest_key="-devcontainer-${project_name}${key}"
    fi

    local dest_dir="${host_projects}/${dest_key}"
    mkdir -p "$dest_dir"

    # Session logs only. Copying every file would let the container plant
    # arbitrary content in ~/.claude/projects/<key>/, including memory/*.md,
    # which host Claude Code loads into its context.
    local copied=0
    while IFS= read -r -d '' file; do
      local rel="${file#"$key_path"}"
      local dest_file="${dest_dir}/${rel}"
      mkdir -p "$(dirname "$dest_file")"

      if [[ ! -e "$dest_file" ]] \
          || [[ "$file" -nt "$dest_file" ]]; then
        cp -p "$file" "$dest_file"
        copied=$((copied + 1))
      fi
    done < <(find "$key_path" -type f -name '*.jsonl' -print0)

    if [[ "$copied" -gt 0 ]]; then
      echo "  Synced ${copied} file(s) -> ${dest_key}"
    fi
    total_copied=$((total_copied + copied))
  done

  # Handle .jsonl files directly in projects/ (no subdirectory).
  local orphan_copied=0
  local dest_dir="${host_projects}/-devcontainer-${project_name}"
  mkdir -p "$dest_dir"

  while IFS= read -r -d '' file; do
    local name
    name=$(basename "$file")
    local dest_file="${dest_dir}/${name}"

    if [[ ! -e "$dest_file" ]] \
        || [[ "$file" -nt "$dest_file" ]]; then
      cp -p "$file" "$dest_file"
      orphan_copied=$((orphan_copied + 1))
    fi
  done < <(find "$tmpdir" -maxdepth 1 -name '*.jsonl' -print0)

  if [[ "$orphan_copied" -gt 0 ]]; then
    echo "  Synced ${orphan_copied} file(s) -> -devcontainer-${project_name}"
    total_copied=$((total_copied + orphan_copied))
  fi

  rm -rf "$tmpdir"

  echo "  Total: ${total_copied} file(s) synced."
}

cmd_cp() {
  local container_path="${1:-}"
  local host_path="${2:-}"

  if [[ -z "$container_path" ]] || [[ -z "$host_path" ]]; then
    log_error "Usage: devc cp <container_path> <host_path>"
    exit 1
  fi

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  # Find the running container
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -z "$container_id" ]]; then
    log_error "No running devcontainer found for $workspace_folder"
    exit 1
  fi

  log_info "Copying $container_path → $host_path"
  docker cp "$container_id:$container_path" "$host_path"
  log_success "Copied $container_path → $host_path"
}

cmd_self_install() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/devc"

  mkdir -p "$install_dir"

  # Create a symlink to the original script
  ln -sf "$SCRIPT_DIR/$SCRIPT_NAME" "$install_path"

  log_success "Installed 'devc' to $install_path"

  # Check if in PATH
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    log_warn "$install_dir is not in your PATH"
    log_info "Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

cmd_update() {
  log_info "Updating devc..."

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not a git repository: $SCRIPT_DIR"
    log_info "Re-clone with: rm -rf ~/.claude-devcontainer && git clone https://github.com/0xdea/zed-claude-devcontainer ~/.claude-devcontainer"
    exit 1
  fi

  local before_sha after_sha
  before_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    log_error "Update failed. Try: cd $SCRIPT_DIR && git pull"
    exit 1
  fi

  after_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if [[ "$before_sha" == "$after_sha" ]]; then
    log_success "Already up to date"
  else
    log_success "Updated from ${before_sha:0:7} to ${after_sha:0:7}"
  fi
}

cmd_dot() {
  # Install template and start container in one command
  cmd_template "."
  note_dotfiles "."
  cmd_up "."
}

# Discovers all Docker resources associated with the current workspace.
# Sets global variables: CONTAINER_ID, CONTAINER_STATUS, VOLUMES (array), IMAGE, IMAGE_UID
discover_resources() {
  local workspace_folder="$1"
  local label="devcontainer.local_folder=$workspace_folder"

  CONTAINER_ID=""
  CONTAINER_STATUS=""
  VOLUMES=()
  IMAGE=""
  IMAGE_UID=""

  # Find container (any state: running, stopped, created, etc.)
  CONTAINER_ID=$(docker ps -aq --filter "label=$label" 2>/dev/null | head -1)

  if [[ -z "$CONTAINER_ID" ]]; then
    return 0
  fi

  # Get container status
  CONTAINER_STATUS=$(docker inspect "$CONTAINER_ID" --format '{{.State.Status}}' 2>/dev/null || true)

  # Get volumes (docker volumes only, not bind mounts)
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && VOLUMES+=("$vol")
  done < <(docker inspect "$CONTAINER_ID" --format '{{json .Mounts}}' 2>/dev/null \
    | jq -r '.[] | select(.Type == "volume") | .Name' 2>/dev/null)

  # Get image and its -uid variant
  IMAGE=$(docker inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [[ -n "$IMAGE" ]]; then
    if [[ "$IMAGE" == *-uid ]]; then
      IMAGE_UID="$IMAGE"
      IMAGE="${IMAGE%-uid}"
    else
      IMAGE_UID="${IMAGE}-uid"
    fi
  fi
}

print_destroy_summary() {
  echo ""
  log_warn "The following resources will be permanently removed:"
  echo ""

  if [[ -n "$CONTAINER_ID" ]]; then
    local container_name
    container_name=$(docker inspect "$CONTAINER_ID" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    echo "  Container:  ${container_name:-$CONTAINER_ID}"
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
      echo "              (currently running -- will be force-stopped)"
    fi
  fi

  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    echo "  Volumes:"
    for vol in "${VOLUMES[@]}"; do
      echo "              $vol"
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    echo "  Image:      $IMAGE"
    if docker image inspect "$IMAGE_UID" &>/dev/null; then
      echo "              $IMAGE_UID"
    fi
  fi

  echo ""
}

cmd_destroy() {
  local force=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=true
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_jq
  discover_resources "$workspace_folder"

  # No resources found (idempotent behavior)
  if [[ -z "$CONTAINER_ID" ]]; then
    log_info "No devcontainer found for $workspace_folder"
    return 0
  fi

  print_destroy_summary

  # Running container warning
  if [[ "$CONTAINER_STATUS" == "running" && "$force" != true ]]; then
    log_warn "Container is currently running!"
    read -p "Force-stop the running container? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Main confirmation prompt
  if [[ "$force" != true ]]; then
    read -p "Destroy these resources? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Deletion, in order: stop, remove container, volumes, images
  if [[ -n "$CONTAINER_ID" && "$CONTAINER_STATUS" == "running" ]]; then
    log_info "Stopping container..."
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CONTAINER_ID" ]]; then
    log_info "Removing container..."
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  # bash 3.2 + set -u: expanding an empty array is an unbound variable error
  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    for vol in "${VOLUMES[@]}"; do
      log_info "Removing volume: $vol"
      docker volume rm -f "$vol" >/dev/null 2>&1 || true
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    log_info "Removing image: $IMAGE"
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    if docker image inspect "$IMAGE_UID" &>/dev/null 2>&1; then
      log_info "Removing image: $IMAGE_UID"
      docker rmi -f "$IMAGE_UID" >/dev/null 2>&1 || true
    fi
  fi

  log_success "All resources destroyed for $workspace_folder"
}

# Main command dispatcher
main() {
  if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
  .)
    cmd_dot
    ;;
  up)
    cmd_up "$@"
    ;;
  rebuild)
    cmd_rebuild "$@"
    ;;
  down)
    cmd_down "$@"
    ;;
  net)
    cmd_net "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  shell)
    cmd_shell
    ;;
  exec)
    [[ "${1:-}" == "--" ]] && shift
    cmd_exec "$@"
    ;;
  upgrade)
    cmd_upgrade
    ;;
  mount)
    cmd_mount "$@"
    ;;
  sync)
    cmd_sync "$@"
    ;;
  cp)
    cmd_cp "$@"
    ;;
  self-install)
    cmd_self_install
    ;;
  update)
    cmd_update
    ;;
  template)
    cmd_template "$@"
    ;;
  help | --help | -h)
    print_usage
    ;;
  *)
    log_error "Unknown command: $command"
    print_usage
    exit 1
    ;;
  esac
}

main "$@"
