# zed-claude-devcontainer

[![](https://img.shields.io/github/stars/0xdea/zed-claude-devcontainer.svg?style=flat&color=yellow)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/forks/0xdea/zed-claude-devcontainer.svg?style=flat&color=green)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/watchers/0xdea/zed-claude-devcontainer.svg?style=flat&color=red)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/badge/twitter-%400xdea-blue.svg)](https://twitter.com/0xdea)
[![](https://img.shields.io/badge/mastodon-%40raptor-purple.svg)](https://infosec.exchange/@raptor)

> "Our robot overlords will use NUL-terminated strings."
>
> -- Matthew Garrett

A containerized development environment for running [Claude Code](https://claude.com/product/claude-code) with
`bypassPermissions` enabled, with support for [Zed](https://zed.dev). Designed for security audit workflows and Rust
development.

> [!TIP]
> See also [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)'s README for
> the original template's documentation, which is more general and covers: Colima Apple Silicon optimizations,
> token-based authentication (headless), CLI helper commands, session sync for `/insights`, file sharing, network
> isolation, threat model, container details, and troubleshooting.

## About this fork

This project is based on
[trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer), licensed under the
Apache License 2.0. Main changes from upstream:

- **Zed only**: the `customizations.vscode` block (VS Code extensions and settings) is removed, and the documentation
  covers Zed and the terminal instead of VS Code and Cursor.
- **Project path**: each project is mounted at `/workspaces/<folder name>` instead of `/workspace`, so Zed shows each
  project under its own name instead of all as "workspace".
- **`postCreateCommand` fix**: Zed mangles string-form lifecycle commands
  (<https://github.com/zed-industries/zed/issues/62964>), so `post_install.py` never ran. The command now uses the
  equivalent exec (array) form, which works in Zed, VS Code, and the devcontainers CLI (proposed upstream in
  <https://github.com/trailofbits/claude-code-devcontainer/pull/56>).
- **Umask workaround**: Zed starts processes in the container via `docker exec`, and some Docker engines (OrbStack among
  them) give `docker exec` processes umask `0000`, which leaves newly created files world-writable. The image restores
  umask `022` in the system-wide init for bash, zsh, and fish. Processes that don't start a shell keep `0000`.
- **Git settings in `containerEnv`**: `core.checkStat=minimal` and `core.trustctime=false` are set through
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*`, so git doesn't treat bind-mounted files as modified just
  because their inode or ctime metadata differs from what the host recorded. Environment variables are used because the
  host `~/.gitconfig` is mounted read-only.
- **fish as the default shell**: fish is the login shell, `$SHELL`, and the `devc shell` default, with the `.zshrc`
  aliases and fzf integration ported to `devcontainer.fish` and its history kept on the `/commandhistory` volume. Claude
  Code's Bash tool stays on zsh via `CLAUDE_CODE_SHELL`.
- **Neovim**: installed from GitHub releases, since the Ubuntu package is too old for current lazy.nvim.
- **Dotfiles**: a dotfiles repo (`DOTFILES_REPO` build arg) is cloned and stowed; `claude` is stowed in
  `post_install.py` because `~/.claude` is a volume.
- **Rust toolchain**: installed via rustup with `rustfmt`, `clippy`, and `rust-analyzer`, with cargo on `PATH` for all
  shells and non-shell processes.
- **GUI/automation dependencies**: `libxdo-dev` for mouse/keyboard automation crates and `xvfb` for running tests
  against a virtual X display.
- **JSON schema**: `devcontainer.json` uses the base devcontainer schema, avoiding an unresolvable `vscode://` reference
  that editors other than VS Code report as an error.

> [!NOTE]
> Because of the umask issue, files created by Zed's remote server and the processes it launches (such as language
> servers and `cargo check`) can end up world-writable on the host. Git only records the executable bit, so this never
> reaches a remote. To find such files in a project from the host, and to remove group and other write access:
>
> ```sh
> find <project> \( -type f -o -type d \) -perm -0002
> find <project> \( -type f -o -type d \) -perm -0002 -exec chmod go-w {} +
> ```

## Why use this?

Running Claude with `bypassPermissions` on your host machine is risky—it can execute any command without confirmation.
This devcontainer provides **filesystem isolation**, so unrestricted Claude reaches only your project directory and a
disposable container, not the rest of your host.

**Designed for:**

- **Security audits**: Review client code without exposing your host
- **Untrusted repositories**: Explore unknown codebases safely
- **Experimental work**: Let Claude modify code freely in isolation
- **Multi-repo engagements**: Work on multiple related repositories

## Prerequisites

- **Docker runtime** (one of):
  - [OrbStack](https://orbstack.dev/) - recommended for Apple Silicon
  - [Docker Desktop](https://docker.com/products/docker-desktop) - untested
  - [Colima](https://github.com/abiosoft/colima): `brew install colima docker && colima start` - untested

- **[Zed](https://zed.dev/)** with dev container support (optional, you can also work from the terminal)

- **`devc` and the devcontainers CLI** (one-time install, needed with or without Zed):

  ```sh
  npm install -g @devcontainers/cli
  git clone https://github.com/0xdea/zed-claude-devcontainer ~/.claude-devcontainer
  ~/.claude-devcontainer/install.sh self-install
  ```

## Quick start

Set up every project with `devc` on the host first, then open it in Zed. Choose the pattern that fits your workflow:

### Pattern A: per-project container (git repository)

Each project gets its own container with independent volumes. Best for one-off reviews or when you need isolation
between projects.

```sh
git clone <untrusted-repo>
cd untrusted-repo
devc .          # Installs .devcontainer/ + starts container
```

The project's `.git/config` and `.git/hooks` are mounted read-only, so code in the container can't plant git hooks or
config that would run on your host.

### Pattern B: shared workspace container (not a git repository)

A parent directory contains the devcontainer config, and you clone multiple repos inside. Shared volumes across all
repos. Best for client engagements, related repositories, or ongoing work.

Create workspace for a client engagement:

```sh
mkdir -p ~/sandbox/client-name
cd ~/sandbox/client-name
devc .          # Installs .devcontainer/ + starts container
```

> [!WARNING]
> **Don't skip `devc`.** Zed reads `devcontainer.json` directly. In a folder that isn't a git repository, the template's
> `.git` mounts make Zed fail with `bind source path does not exist: .../.git/config` until `devc` has removed them.

Then clone repos inside the workspace, from the host or from the container:

```sh
git clone <client-repo-1>
git clone <client-repo-2>
```

> [!NOTE]
> The repos inside the workspace don't get the read-only `.git` protection; only the workspace root does. If you later
> run `git init` in the workspace itself, run `devc template .` to restore the `.git` mounts.

### Opening the project in Zed

1. Open the **project folder** (the one containing `.devcontainer/`) in Zed.
2. Choose **Open in Container** when Zed detects `.devcontainer/devcontainer.json` and prompts you. Alternatively, open
   the command palette (`Cmd+Shift+P` on Mac, `Ctrl+Shift+P` on Linux), run **Project: Open Remote**, and select
   **Connect Dev Container**.

Zed attaches to the container `devc` started, and its terminal and language servers run inside the container.

> [!WARNING]
> Extensions listed under `customizations.zed.extensions` in `devcontainer.json` are also installed in your local Zed
> ([Zed docs](https://zed.dev/docs/dev-containers)). The bundled template lists none; check this field before opening a
> project whose `.devcontainer/` you didn't create.

### Terminal only

Zed is optional. `devc shell` opens a fish shell in the container, where you can run `claude` directly.

## Updating and rebuilding

Zed never rebuilds the container on its own, even when `devcontainer.json` changes. Run these on the host from the
project folder:

| Goal                                                                         | Commands                                         |
| ---------------------------------------------------------------------------- | ------------------------------------------------ |
| Pick up a new version of this template                                       | `devc update`, `devc template .`, `devc rebuild` |
| Apply your own edits to `.devcontainer/`, or a new `CLAUDE_CODE_OAUTH_TOKEN` | `devc rebuild`                                   |
| Upgrade Claude Code only                                                     | `devc upgrade`                                   |
| Start over with empty volumes                                                | `devc destroy`, then `devc .`                    |

- **`devc update`** pulls the latest version of `devc` and the template into `~/.claude-devcontainer`. It doesn't touch
  your projects.
- **`devc template .`** asks before overwriting the project's `.devcontainer/`, then copies the new template in. It
  keeps mounts you added with `devc mount`, and removes the `.git` mounts again in a non-git workspace. Your other edits
  to `.devcontainer/` are overwritten.
- **`devc rebuild`** rebuilds the image and recreates the container. The volumes for shell history, Claude config, and
  `gh` login are kept. Docker reuses cached layers whose Dockerfile step hasn't changed (see [Dotfiles](#dotfiles)).
- **`devc destroy`** deletes the container, volumes, and image, including your Claude login and settings for that
  project.

> [!NOTE]
> After a rebuild, an open Zed window loses its connection to the old container and shows "container is not running".
> Reopen the project with **Project: Open Remote** -> **Connect Dev Container**.

## Customizing the image

How long a customization lasts depends on where you make it.

### Ad hoc: until the next rebuild

```sh
devc exec sudo apt-get install -y <package>
```

Anything installed this way disappears when the container is recreated by `devc rebuild` or `devc destroy`. Good for a
one-off tool during a review.

### Per project: until the next `devc template .`

Edit the project's `.devcontainer/Dockerfile` or `.devcontainer/devcontainer.json`, then run `devc rebuild`. For
example, to use your own dotfiles in one project:

```json
"build": {
  "dockerfile": "Dockerfile",
  "args": {
    "TZ": "${localEnv:TZ:UTC}",
    "DOTFILES_REPO": "https://github.com/<you>/dotfiles.git"
  }
}
```

Other build args you can set the same way: `NODE_VERSION`, `NEOVIM_VERSION`, `FZF_VERSION`, `GIT_DELTA_VERSION`, and
`ZSH_IN_DOCKER_VERSION`.

`devc template .` overwrites these files and keeps only the mounts added with `devc mount`, so you have to reapply other
edits after updating the template.

### All projects: survives updates

`devc template` copies its files from the clone at `~/.claude-devcontainer`. To customize every project, keep your
changes in a fork and point that clone at it:

1. Fork this repository and commit your changes to the fork. For example, change the `DOTFILES_REPO` default in the
   `Dockerfile`, or add packages to its `apt-get install` list.
2. Point `devc` at your fork and pull:

   ```sh
   git -C ~/.claude-devcontainer remote set-url origin https://github.com/<you>/zed-claude-devcontainer
   devc update
   ```

3. In each project, run `devc template .` and `devc rebuild`.

Commit to the fork, not to `~/.claude-devcontainer` directly: `devc update` runs `git pull --ff-only`, which fails once
local commits and the fork have diverged. To pick up later changes from this repository, merge it into your fork.

### Dotfiles

The image clones `DOTFILES_REPO` at build time and stows it into `~/` with GNU Stow:

- **Required packages.** The repo must contain `fish`, `nvim`, and `tmux` packages: top-level directories laid out like
  your home directory, such as `fish/.config/fish/config.fish`. If one is missing, the build fails with
  `stow: ERROR: The stow directory ... does not contain package nvim`. To stow a different set, edit the `stow` line in
  the `Dockerfile`.
- **Optional `claude` package.** If present, `post_install.py` stows it into `~/.claude` when the container is created,
  since `~/.claude` is a volume that would hide anything stowed at build time.
- **Public HTTPS URL.** The image build has no access to your SSH keys, so the repo must be cloneable without
  credentials.
- **Updates aren't picked up by `devc rebuild`.** Docker caches the clone step, so new commits in your dotfiles repo
  don't reach the image. To refresh the running container, pull inside it (the stowed files are symlinks, so edits apply
  immediately; re-run `stow` only for new files):

  ```sh
  git -C ~/.dotfiles pull
  stow --no-folding -R -d ~/.dotfiles -t ~ fish nvim tmux
  ```

  This lasts until the container is recreated. To bake the new commits into the image, rebuild without the cache from
  the project folder (slow, since every layer is rebuilt; volumes are kept):

  ```sh
  devcontainer up --workspace-folder . --remove-existing-container --build-no-cache
  ```

## Development

The template files live at the top of this repository, not in a `.devcontainer/` folder, so the devcontainers CLI can't
use the repository itself as a workspace. Install your working copy into a scratch folder instead. Run `./install.sh`
from the working copy, since the `devc` command copies the template from `~/.claude-devcontainer`:

```sh
mkdir -p ~/devc-test
git -C ~/devc-test init           # skip to test a non-git workspace
./install.sh template ~/devc-test
cd ~/devc-test
devc up                           # builds the image and starts the container
devc shell
```

After each change, run `./install.sh template ~/devc-test` again (answer `y`) and then `devc rebuild` in the scratch
folder. To test changes to `install.sh` itself, run the working copy's script, for example
`~/path/to/repo/install.sh rebuild`. When you're done, run `devc destroy -f` in the scratch folder to remove its
container, volumes, and image.
