# zed-claude-devcontainer

[![](https://img.shields.io/github/stars/0xdea/zed-claude-devcontainer.svg?style=flat&color=yellow)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/forks/0xdea/zed-claude-devcontainer.svg?style=flat&color=green)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/watchers/0xdea/zed-claude-devcontainer.svg?style=flat&color=red)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/badge/twitter-%400xdea-blue.svg)](https://twitter.com/0xdea)
[![](https://img.shields.io/badge/mastodon-%40raptor-purple.svg)](https://infosec.exchange/@raptor)

> "Our robot overlords will use NUL-terminated strings."
>
> -- Matthew Garrett

A containerized development environment for running Claude Code with `bypassPermissions` enabled, with support for Zed. Designed for security audit workflows and Rust development.

## About This Fork

zed-claude-devcontainer is based on [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer), licensed under the Apache License 2.0. Main changes from upstream:

- **Zed support**: Zed starts processes in the container via `docker exec`, and some Docker engines, OrbStack among them, give `docker exec` processes umask `0000`, which leaves newly created files world-writable. The image restores umask `022` in the system-wide init for bash, zsh, and fish. Processes that don't start a shell keep `0000`; see [Troubleshooting](#files-on-the-host-are-world-writable).
- **Zed only**: the `customizations.vscode` block (VS Code extensions and settings) is removed, and the documentation covers Zed and the terminal instead of VS Code and Cursor.
- **Project path**: each project is mounted at `/workspaces/<folder name>` instead of `/workspace`, so Zed shows each project under its own name instead of all as "workspace". `devc template` recognizes the old `/workspace` mounts when updating a project, and `devc sync` stores sessions from old and new containers under the same host keys.
- **`postCreateCommand` fix**: Zed mangles string-form lifecycle commands ([zed-industries/zed#62964](https://github.com/zed-industries/zed/issues/62964)), so `post_install.py` never ran. The command now uses the equivalent exec (array) form, which works in Zed, VS Code, and the devcontainers CLI (proposed upstream in [#56](https://github.com/trailofbits/claude-code-devcontainer/pull/56)).
- **Git settings in `containerEnv`**: `core.checkStat=minimal` and `core.trustctime=false` are set through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*`, so git doesn't treat bind-mounted files as modified just because their inode or ctime metadata differs from what the host recorded. Environment variables are used because the host `~/.gitconfig` is mounted read-only.
- **fish as the default shell**: fish is the login shell, `$SHELL`, and the `devc shell` default, with the `.zshrc` aliases and fzf integration ported to `devcontainer.fish` and its history kept on the `/commandhistory` volume. Claude Code's Bash tool stays on zsh via `CLAUDE_CODE_SHELL`.
- **Rust toolchain**: installed via rustup with `rustfmt`, `clippy`, and `rust-analyzer`, with cargo on `PATH` for all shells and non-shell processes.
- **Neovim**: installed from GitHub releases, since the Ubuntu package is too old for current lazy.nvim.
- **Dotfiles**: a dotfiles repo (`DOTFILES_REPO` build arg) is cloned and stowed; `claude` is stowed in `post_install.py` because `~/.claude` is a volume.
- **GUI/automation dependencies**: `libxdo-dev` for mouse/keyboard automation crates and `xvfb` for running tests against a virtual X display.
- **JSON schema**: `devcontainer.json` uses the base devcontainer schema, avoiding an unresolvable `vscode://` reference that editors other than VS Code report as an error.

## Why Use This?

Running Claude with `bypassPermissions` on your host machine is risky—it can execute any command without confirmation. This devcontainer provides **filesystem isolation**, so unrestricted Claude reaches only your project directory and a disposable container, not the rest of your host.

**Designed for:**

- **Security audits**: Review client code without exposing your host
- **Untrusted repositories**: Explore unknown codebases safely
- **Experimental work**: Let Claude modify code freely in isolation
- **Multi-repo engagements**: Work on multiple related repositories

## Prerequisites

- **Docker runtime** (one of):
  - [Docker Desktop](https://docker.com/products/docker-desktop) - ensure it's running
  - [OrbStack](https://orbstack.dev/) - recommended for Apple Silicon, faster than Docker Desktop
  - [Colima](https://github.com/abiosoft/colima): `brew install colima docker && colima start` - untested

- **[Zed](https://zed.dev/)** with dev container support (optional; you can also work from the terminal)

- **`devc` and the devcontainers CLI** (one-time install, needed with or without Zed):

  ```bash
  npm install -g @devcontainers/cli
  git clone https://github.com/0xdea/zed-claude-devcontainer ~/.claude-devcontainer
  ~/.claude-devcontainer/install.sh self-install
  ```

<details>
<summary><strong>Optimizing Colima for Apple Silicon</strong></summary>

Colima's defaults (QEMU + sshfs) are conservative. For better performance:

```bash
# Stop and delete current VM (removes containers/images)
colima stop && colima delete

# Start with optimized settings
colima start \
  --cpu 4 \
  --memory 8 \
  --disk 100 \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs
```

Adjust `--cpu` and `--memory` based on your Mac (e.g., 6/16 for Pro, 8/32 for Max).

| Option                  | Benefit                                           |
| ----------------------- | ------------------------------------------------- |
| `--vm-type vz`          | Apple Virtualization.framework (faster than QEMU) |
| `--mount-type virtiofs` | 5-10x faster file I/O than sshfs                  |
| `--vz-rosetta`          | Run x86 containers via Rosetta                    |

Verify with `colima status` - should show "macOS Virtualization.Framework" and "virtiofs".

</details>

## Quick Start

Set up every project with `devc` on the host first, then open it in Zed. `devc` adapts `devcontainer.json` to the folder and runs safety checks that Zed doesn't. Choose the pattern that fits your workflow:

### Pattern A: Per-Project Container (Git Repository)

Each project gets its own container with independent volumes. Best for one-off reviews or when you need isolation between projects.

```bash
git clone <untrusted-repo>
cd untrusted-repo
devc .          # Installs .devcontainer/ + starts container
```

The project's `.git/config` and `.git/hooks` are mounted read-only, so code in the container can't plant git hooks or config that would run on your host.

### Pattern B: Shared Workspace Container (Not a Git Repository)

A parent directory contains the devcontainer config, and you clone multiple repos inside. Shared volumes across all repos. Best for client engagements, related repositories, or ongoing work.

```bash
mkdir -p ~/sandbox/client-name
cd ~/sandbox/client-name
devc .          # Installs .devcontainer/ + starts container
```

Since the folder isn't a git repository, `devc` removes the read-only `.git` mounts from its `devcontainer.json` and prints a warning. Docker refuses to start a container when a mount source is missing.

Then clone repos inside the workspace, from the host or from the container:

```bash
git clone <client-repo-1>
git clone <client-repo-2>
```

The repos inside the workspace don't get the read-only `.git` protection; only the workspace root does. If you later run `git init` in the workspace itself, run `devc template .` to restore the `.git` mounts.

> **Don't skip `devc`.** Zed reads `devcontainer.json` directly. In a folder that isn't a git repository, the template's `.git` mounts make Zed fail with `bind source path does not exist: .../.git/config` until `devc` has removed them.

### Opening the Project in Zed

1. Open the **project folder** (the one containing `.devcontainer/`) in Zed.
2. Choose **Open in Container** when Zed detects `.devcontainer/devcontainer.json` and prompts you. Alternatively, open the command palette (`Cmd+Shift+P` on Mac, `Ctrl+Shift+P` on Linux), run **Project: Open Remote**, and select **Connect Dev Container**.

Zed attaches to the container `devc` started, and its terminal and language servers run inside the container.

### Terminal Only

Zed is optional. `devc shell` opens a fish shell in the container, where you can run `claude` directly.

## Updating and Rebuilding

Zed never rebuilds the container on its own, even when `devcontainer.json` changes. Run these on the host from the project folder:

| Goal                                                                         | Commands                                         |
| ---------------------------------------------------------------------------- | ------------------------------------------------ |
| Pick up a new version of this template                                       | `devc update`, `devc template .`, `devc rebuild` |
| Apply your own edits to `.devcontainer/`, or a new `CLAUDE_CODE_OAUTH_TOKEN` | `devc rebuild`                                   |
| Upgrade Claude Code only                                                     | `devc upgrade`                                   |
| Start over with empty volumes                                                | `devc destroy`, then `devc .`                    |

- **`devc update`** pulls the latest version of `devc` and the template into `~/.claude-devcontainer`. It doesn't touch your projects.
- **`devc template .`** asks before overwriting the project's `.devcontainer/`, then copies the new template in. It keeps mounts you added with `devc mount`, and removes the `.git` mounts again in a non-git workspace. Your other edits to `.devcontainer/` are overwritten.
- **`devc rebuild`** rebuilds the image and recreates the container. The volumes for shell history, Claude config, and `gh` login are kept. Docker reuses cached layers whose Dockerfile step hasn't changed (see [Dotfiles](#dotfiles)).
- **`devc destroy`** deletes the container, volumes, and image, including your Claude login and settings for that project.

After a rebuild, an open Zed window loses its connection to the old container and shows "container is not running". Reopen the project with **Project: Open Remote** → **Connect Dev Container**.

## Customizing the Image

How long a customization lasts depends on where you make it.

### Ad Hoc: Until the Next Rebuild

```bash
devc exec sudo apt-get install -y <package>
```

Anything installed this way disappears when the container is recreated by `devc rebuild` or `devc destroy`. Good for a one-off tool during a review.

### Per Project: Until the Next `devc template .`

Edit the project's `.devcontainer/Dockerfile` or `.devcontainer/devcontainer.json`, then run `devc rebuild`. For example, to use your own dotfiles in one project:

```json
"build": {
  "dockerfile": "Dockerfile",
  "args": {
    "TZ": "${localEnv:TZ:UTC}",
    "DOTFILES_REPO": "https://github.com/<you>/dotfiles.git"
  }
}
```

Other build args you can set the same way: `NODE_VERSION`, `NEOVIM_VERSION`, `FZF_VERSION`, `GIT_DELTA_VERSION`, and `ZSH_IN_DOCKER_VERSION`.

`devc template .` overwrites these files and keeps only the mounts added with `devc mount`, so you have to reapply other edits after updating the template.

### All Projects: Survives Updates

`devc template` copies its files from the clone at `~/.claude-devcontainer`. To customize every project, keep your changes in a fork and point that clone at it:

1. Fork this repository and commit your changes to the fork. For example, change the `DOTFILES_REPO` default in the `Dockerfile`, or add packages to its `apt-get install` list.
2. Point `devc` at your fork and pull:

   ```bash
   git -C ~/.claude-devcontainer remote set-url origin https://github.com/<you>/zed-claude-devcontainer
   devc update
   ```

3. In each project, run `devc template .` and `devc rebuild`.

Commit to the fork, not to `~/.claude-devcontainer` directly: `devc update` runs `git pull --ff-only`, which fails once local commits and the fork have diverged. To pick up later changes from this repository, merge it into your fork.

### Dotfiles

The image clones `DOTFILES_REPO` at build time and stows it into `~/` with GNU Stow:

- **Required packages.** The repo must contain `fish`, `nvim`, and `tmux` packages: top-level directories laid out like your home directory, such as `fish/.config/fish/config.fish`. If one is missing, the build fails with `stow: ERROR: The stow directory ... does not contain package nvim`. To stow a different set, edit the `stow` line in the `Dockerfile`.
- **Optional `claude` package.** If present, `post_install.py` stows it into `~/.claude` when the container is created, since `~/.claude` is a volume that would hide anything stowed at build time.
- **Public HTTPS URL.** The image build has no access to your SSH keys, so the repo must be cloneable without credentials.
- **Updates aren't picked up by `devc rebuild`.** Docker caches the clone step, so new commits in your dotfiles repo don't reach the image. To refresh the running container, pull inside it (the stowed files are symlinks, so edits apply immediately; re-run `stow` only for new files):

  ```bash
  git -C ~/.dotfiles pull
  stow --no-folding -R -d ~/.dotfiles -t ~ fish nvim tmux
  ```

  This lasts until the container is recreated. To bake the new commits into the image, rebuild without the cache from the project folder (slow, since every layer is rebuilt; volumes are kept):

  ```bash
  devcontainer up --workspace-folder . --remove-existing-container --build-no-cache
  ```

## Token-Based Auth (Headless)

For headless servers or to skip the interactive login wizard:

```bash
claude setup-token                          # run on host, one-time
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
devc rebuild                                # rebuilds with token
```

The token is forwarded into the container. On each container creation, `post_install.py` runs a one-shot auth handshake so `claude` starts without the login wizard.

This works around Claude Code's interactive onboarding wizard always showing in containers, even with valid credentials ([#8938](https://github.com/anthropics/claude-code/issues/8938)).

If you don't set a token, the interactive login flow works as before.

## CLI Helper Commands

```
devc .              Install template + start container in current directory
devc up             Start the devcontainer
devc rebuild        Rebuild container (preserves persistent volumes)
devc destroy [-f]   Remove container, volumes, and image for current project
devc down           Stop the container
devc shell          Open fish shell in container
devc exec CMD       Execute command inside the container
devc upgrade        Upgrade Claude Code in the container
devc mount SRC DST  Add a bind mount (host → container)
devc sync [NAME]    Sync Claude Code sessions from devcontainers to host
devc cp SRC DST     Copy a path from the container to the host
devc template DIR   Copy devcontainer files to directory
devc self-install   Install devc to ~/.local/bin
devc update         Update devc to the latest version
```

> **Note:** Use `devc destroy` to clean up a project's Docker resources. Removing containers manually (e.g., `docker rm`) will leave orphaned volumes and images behind that `devc destroy` won't be able to find.

## Session Sync for `/insights`

Claude Code's `/insights` command analyzes your session history, but it only reads from `~/.claude/projects/` on the host. Sessions inside devcontainer volumes are invisible to it.

`devc sync` copies session logs from all devcontainers (running and stopped) to the host so `/insights` can include them:

```bash
devc sync              # Sync all devcontainers
devc sync crypto       # Filter by project name (substring match)
```

Devcontainers are auto-discovered via Docker labels — no need to know container names or IDs. The sync is incremental, so it's safe to run repeatedly.

> **Security note:** this copies container-authored data onto your host, so it prompts first (`--trusted` skips it). Only `*.jsonl` logs are copied, always under a `-devcontainer-<project>` key, so a container cannot plant files elsewhere in `~/.claude/projects/`. The transcripts are still container-authored text that a later host session will read.

## File Sharing

Files you put in the project folder on the host are visible in the container under `/workspaces/<folder name>/`, since the project is bind-mounted.

### `devc mount`

To make a host directory available inside the container:

```bash
devc mount ~/drop /drop           # Read-write
devc mount ~/secrets /secrets --readonly
```

This adds a bind mount to `devcontainer.json` and recreates the container. Existing mounts are preserved across `devc template` updates.

**Tip:** A shared "drop folder" is useful for passing files in without mounting your entire home directory.

> **Security note:** Avoid mounting large host directories (e.g., `$HOME`). Every mounted path is writable from inside the container unless `--readonly` is specified, which undermines the filesystem isolation this project provides.

## Network Isolation

By default, containers have full outbound network access. For stricter security, use iptables to restrict network access.

### When to Enable Network Isolation

- Reviewing code that may contain malicious dependencies
- Auditing software with telemetry or phone-home behavior
- Maximum isolation for highly sensitive reviews

### Example: Claude + GitHub + Package Registries

Run this inside the container (`devc shell`). The allowlist lives in an `ipset` that the
`iptables` rule references by name, so refreshing it does not mean re-adding rules.

```bash
# 1. Loopback, plus DNS to whatever resolver the container was given.
#    Without this the final DROP blocks name resolution and nothing works.
sudo iptables -A OUTPUT -o lo -j ACCEPT
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  sudo iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  sudo iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

# 2. Resolve the allowlist into an ipset.
sudo ipset create allowed-egress hash:ip -exist
for host in api.anthropic.com github.com raw.githubusercontent.com \
            registry.npmjs.org pypi.org files.pythonhosted.org; do
  for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
    sudo ipset add allowed-egress "$ip" -exist
  done
done

# 3. Allow the set, drop everything else.
sudo iptables -A OUTPUT -m set --match-set allowed-egress dst -j ACCEPT
sudo iptables -A OUTPUT -j DROP
```

### Trade-offs

- Blocks package managers unless you allowlist registries
- May break tools that require network access
- DNS is permitted (DNS remains an exfiltration channel)
- The allowlist is per-IP, so any other site behind the same CDN address is also reachable
- IPv6 is not filtered. If your Docker network has an IPv6 default route, mirror the
  rules with `ip6tables` and an `ipset ... family inet6`
- Rules are lost on container restart; re-apply them per session

## Threat Model

**Protects against:**

- Claude with `bypassPermissions` running wild during a session.
- Direct access to your SSH key material and other credentials
- Unrestricted, direct access to the whole filesystem
- Cross-engagement leakage

**Does not protect against:**

- **Container escape.** A container is containment, not a strong security boundary. Escape should be hard, not impossible.
- **Deferred escape.** Container-planted code can get executed on the host, when the user performs some action on the host. Planting files under shared `.git` folder is an example escape path.
- **Zed dev container extensions.** Extensions listed under `customizations.zed.extensions` in `devcontainer.json` are also installed in your local Zed ([Zed docs](https://zed.dev/docs/dev-containers)). The bundled template lists none; review this field before opening a project whose `.devcontainer/` you didn't create.
- **Editor attack surface.** Zed on the host talks to a server running inside the container. Treat that channel as untrusted input to your host editor, not as an isolation boundary.
- **Network rules overwrite.** Container has `NET_ADMIN` and passwordless sudo, its user can change the iptables rules dynamically.
- **Exfiltration of in-container credentials.** Claude, GitHub, and other tokens provided to container are simply accessible inside it.

**Also not isolated:** forwarded SSH agent (container code can authenticate as you; keys stay on the host), `~/.gitconfig` (read-only). The Docker socket is not mounted.

## Container Details

| Component                  | Details                                                                                                                                                                                                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Base                       | Ubuntu 24.04, Node.js 24, Python 3.13 + uv, Rust (rustup), fish (default) + zsh                                                                                                                                                                                                |
| User                       | `vscode` (passwordless sudo), working dir `/workspaces/<folder name>`                                                                                                                                                                                                          |
| Tools                      | `rg`, `fd`, `tmux`, `fzf`, `delta`, `nvim`, `stow`, `iptables`, `ipset`                                                                                                                                                                                                        |
| Volumes (survive rebuilds) | Command history (`/commandhistory`), Claude config (`~/.claude`), GitHub CLI auth (`~/.config/gh`)                                                                                                                                                                             |
| Host mounts                | `~/.gitconfig`, `.devcontainer/`, `.git/config`, `.git/hooks/` (all read-only)                                                                                                                                                                                                 |
| Dotfiles                   | [0xdea/dotfiles](https://github.com/0xdea/dotfiles) cloned to `~/.dotfiles` and stowed (`fish`, `nvim`, `tmux`, `claude`); override with the `DOTFILES_REPO` build arg                                                                                                         |
| Auto-configured            | `bypassPermissions` mode (via `post_install.py`), skills from [anthropics/skills](https://github.com/anthropics/skills) + [trailofbits/skills](https://github.com/trailofbits/skills) + [trailofbits/skills-curated](https://github.com/trailofbits/skills-curated), git-delta |

Volumes are stored outside the container, so your shell history, Claude settings, and `gh` login persist even after `devc rebuild`. Host `~/.gitconfig` is mounted read-only for git identity.

The container ships common development tooling so you can do all your work inside it, not just run Claude. The intended workflow is: clone a repository, start the container, and stay in it. If you need extra runtimes, see [Customizing the Image](#customizing-the-image).

## Troubleshooting

### "devcontainer CLI not found"

```bash
npm install -g @devcontainers/cli
```

### Container won't start

1. Check Docker is running
2. Try rebuilding: `devc rebuild`
3. Check logs: `docker logs $(docker ps -lq)`

### GitHub CLI auth not persisting

The gh volume may need ownership fix:

```bash
sudo chown -R $(id -u):$(id -g) ~/.config/gh
```

### Python/uv not working

Python is managed via uv:

```bash
uv run script.py              # Run a script
uv add package                # Add project dependency
uv run --with requests py.py  # Ad-hoc dependency
```

### npm can't install a recently published version

To reduce exposure to compromised releases, npm in the container only installs versions published at least a day ago (`NPM_CONFIG_MIN_RELEASE_AGE=1`). If a dependency needs a newer version, `npm install` fails with no matching version, and `npm audit fix` keeps a vulnerable version when its fix is too recent. To allow it for one command, or to exempt a package:

```bash
npm install --min-release-age=0
npm install --min-release-age-exclude=<package>
```

### Files on the host are world-writable

On Docker engines that give `docker exec` processes umask `0000` (OrbStack does), processes that don't start a shell create world-writable files. That includes Zed's remote server, which saves your edits, and what it launches, such as language servers, `cargo check`, and Zed's git operations. Shells in the container restore umask `022`, so files created from a terminal are fine. The project folder is shared with the host, so these files are writable by other local users there too. Git only records the executable bit, so the extra permissions never reach a remote.

To check a project from the host, and to remove group and other write access:

```bash
find <project> \( -type f -o -type d \) -perm -0002
find <project> \( -type f -o -type d \) -perm -0002 -exec chmod go-w {} +
```

The `-type` filter skips symlinks, which `chmod` would otherwise follow. To see what your engine does, run `docker exec <container> sh -c umask`.

### Git can't write `.git/config` inside the container

The project's `.git/config` and `.git/hooks` are mounted read-only, so code in the container can't plant config or hooks that later run on your host. Commands that write repository config fail inside the container, for example `git remote add`, `git config` without `--global`, or `git push -u`. Run them on the host instead.

### Container doesn't see host changes to `.git/config` or `~/.gitconfig`

Both are mounted as single files. Git saves config by writing a new file and renaming it over the old one, and a single-file bind mount stays attached to the old file. After changing either on the host, for example adding a remote or running `git config --global`, run `devc rebuild` to pick up the change.

## Development

The template files live at the top of this repository, not in a `.devcontainer/` folder, so the devcontainers CLI can't use the repository itself as a workspace. Install your working copy into a scratch folder instead. Run `./install.sh` from the working copy, since the `devc` command copies the template from `~/.claude-devcontainer`:

```bash
mkdir -p ~/devc-test
git -C ~/devc-test init           # skip to test a non-git workspace
./install.sh template ~/devc-test
cd ~/devc-test
devc up                           # builds the image and starts the container
devc shell
```

After each change, run `./install.sh template ~/devc-test` again (answer `y`) and then `devc rebuild` in the scratch folder. To test changes to `install.sh` itself, run the working copy's script, for example `~/path/to/repo/install.sh rebuild`. When you're done, run `devc destroy -f` in the scratch folder to remove its container, volumes, and image.
