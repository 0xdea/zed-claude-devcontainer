# zed-claude-devcontainer

[![](https://img.shields.io/github/stars/0xdea/zed-claude-devcontainer.svg?style=flat&color=yellow)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/forks/0xdea/zed-claude-devcontainer.svg?style=flat&color=green)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/github/watchers/0xdea/zed-claude-devcontainer.svg?style=flat&color=red)](https://github.com/0xdea/zed-claude-devcontainer)
[![](https://img.shields.io/badge/zed-1.x-violet)](https://zed.dev/)
[![](https://img.shields.io/badge/twitter-%400xdea-blue.svg)](https://twitter.com/0xdea)
[![](https://img.shields.io/badge/mastodon-%40raptor-purple.svg)](https://infosec.exchange/@raptor)
[![build](https://github.com/0xdea/zed-claude-devcontainer/actions/workflows/build.yml/badge.svg)](https://github.com/0xdea/zed-claude-devcontainer/actions/workflows/build.yml)

> "Our robot overlords will use NUL-terminated strings."
>
> -- Matthew Garrett

A sandboxed dev container for running [Claude Code](https://claude.com/product/claude-code) with `bypassPermissions`
enabled, from [Zed](https://zed.dev) or a terminal. Designed for security audits and Rust development.

## About this fork

Based on [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) (Apache
License 2.0).

> [!TIP]
> The [upstream README](https://github.com/trailofbits/claude-code-devcontainer#readme) covers what this one doesn't:
> Colima tuning, token-based (headless) authentication, the full `devc` command list, session sync for `/insights`,
> file sharing, network isolation, threat model, and container details.

Changes from upstream:

- **Zed**: the VS Code customizations are removed, and these docs cover Zed and the terminal.
- **Project path**: projects are mounted at `/workspaces/<folder name>`, not `/workspace`, so Zed shows each project's
  name.
- **umask**: fish, zsh, and interactive bash restore umask `022`, because some engines start `docker exec` processes
  with `0000` (see [Known issues](#world-writable-files-on-the-host)).
- **fish**: the login shell, `$SHELL`, and `devc shell` default, with `.zshrc`'s aliases and fzf integration in
  `devcontainer.fish` and history on the `/commandhistory` volume. Claude Code's Bash tool still uses zsh.
- **Tools**: Neovim from GitHub releases (Ubuntu's is too old for lazy.nvim); Rust via rustup with `rustfmt`,
  `clippy`, `rust-analyzer`, and the `wasm32-wasip2` target; `cargo-audit`, `cargo-deny`, `cargo-semver-checks`,
  `cargo-nextest`, `cargo-generate`, `cargo-dylint`, and `dylint-link` via
  [cargo-binstall](https://github.com/cargo-bins/cargo-binstall) from each project's release binaries (compiling from
  crates.io as a fallback, without QuickInstall builds or telemetry); [zizmor](https://github.com/zizmorcore/zizmor)
  via uv; `libxdo-dev` and `xvfb` for GUI automation and tests on a virtual display.
- **Dotfiles**: cloned from `DOTFILES_REPO` and stowed (see [Dotfiles](#dotfiles)).
- **`devc rebuild --no-cache`**: rebuilds without Docker's build cache, still running `devc`'s checks.
- **Schema**: `devcontainer.json` uses the base schema, avoiding a `vscode://` reference other editors can't resolve.
- **CI and updates**: a `build` workflow lints the template, builds and checks the image, and runs zizmor. Renovate
  also tracks the Node.js and Python series and the CI's hadolint image, with a 10-day minimum release age.

Merged upstream: the exec-form `postCreateCommand`, since Zed mangles string-form lifecycle commands
([zed-industries/zed#62964](https://github.com/zed-industries/zed/issues/62964)), in
[#56](https://github.com/trailofbits/claude-code-devcontainer/pull/56); git settings that stop bind-mounted files from
showing as modified, and the `gh` credential helper across rebuilds, in
[#59](https://github.com/trailofbits/claude-code-devcontainer/pull/59).

## Why use this?

Running Claude with `bypassPermissions` on your host lets it run any command without asking. Here it can only reach
the project folder and a disposable container. Use it for security audits of client code, exploring untrusted
repositories, letting Claude change code freely, and work across several related repositories.

## Prerequisites

- A Docker engine: [OrbStack](https://orbstack.dev/) (recommended on Apple Silicon), or the untested
  [Docker Desktop](https://docker.com/products/docker-desktop) or [Colima](https://github.com/abiosoft/colima)
  (`brew install colima docker && colima start`).
- [Zed](https://zed.dev/), optional.
- [jq](https://jqlang.org/), which `devc` uses to edit `devcontainer.json` (included in macOS 15 and later).
- [Node.js](https://nodejs.org/) and npm.
- `devc` and the Dev Container CLI, installed once:

  ```sh
  npm install -g @devcontainers/cli
  git clone https://github.com/0xdea/zed-claude-devcontainer ~/.claude-devcontainer
  ~/.claude-devcontainer/install.sh self-install
  ```

## Quick start

Set up every project with `devc` on the host before opening it in Zed.

### Pattern A: one repository per container

Each project gets its own container and volumes. Best for one-off reviews and code you don't trust.

```sh
git clone <untrusted-repo>
cd untrusted-repo
devc .          # installs .devcontainer/ and starts the container
```

The repository's `.git/config` and `.git/hooks` are mounted read-only, so code in the container can't plant git config
or hooks that run on your host. Git commands that write the config fail there, such as `git remote add` and `git config`
without `--global`. `git push -u` pushes but can't record the upstream branch, so set it on the host.

The container's global gitignore excludes paths such as `.claude/`, `.vscode/`, `.idea/`, `.zed/`, and `*.log`, so files planted
under those names don't show up in `git status` inside the container. Check with `git status --ignored`, or on the host.

### Pattern B: shared workspace (not a git repository)

Several repositories share one container and its volumes. Best for related repositories you trust.

```sh
mkdir -p ~/sandbox/workspace-name
cd ~/sandbox/workspace-name
devc .          # installs .devcontainer/ and starts the container
git clone <repo-1>
git clone <repo-2>
```

Here `devc` removes the template's `.git` mounts; without it, Zed fails with
`bind source path does not exist: .../.git/config`. If you later run `git init` in the workspace, run
`devc template .` to restore them.

> [!WARNING]
> Repositories inside the workspace aren't protected: code in the container can change their `.git/config` and
> `.git/hooks`, which git runs on your host the next time you use it there. Use Pattern A for code you don't trust.

### Opening the project

Open the project folder in Zed and choose **Open in Container**, or run **Project: Open Remote** → **Connect Dev
Container** from the command palette. Zed attaches to the container `devc` started; its terminal and language servers
run inside it. Without Zed, `devc shell` opens a fish shell in the container.

> [!WARNING]
> Only open projects whose `.devcontainer/` came from `devc`. If a repository ships its own, `devc .` asks before
> replacing it; answer `y`. Otherwise Zed uses the repository's `devcontainer.json`, which can run commands on your
> host (`initializeCommand`), mount host folders, weaken the container's isolation, and install extensions in your
> local Zed (`customizations.zed.extensions`, see the [Zed docs](https://zed.dev/docs/dev-containers)).

## Updating and rebuilding

Run these on the host, in the project folder. Zed never rebuilds the container by itself.

| Goal                                                                     | Commands                                         |
| ------------------------------------------------------------------------ | ------------------------------------------------ |
| Pick up a new version of this template                                   | `devc update`, `devc template .`, `devc rebuild` |
| Apply your edits to `.devcontainer/`, or a new `CLAUDE_CODE_OAUTH_TOKEN` | `devc rebuild`                                   |
| Get the latest Claude Code, Rust and cargo tools, apt packages, dotfiles | `devc rebuild --no-cache`                        |
| Get the latest Claude Code only                                          | `devc upgrade`                                   |
| Start over with empty volumes                                            | `devc destroy`, then `devc .`                    |

- `devc update` updates `devc` and the template in `~/.claude-devcontainer`; projects aren't touched.
- `devc template .` replaces the project's `.devcontainer/` after asking. It keeps only mounts added with
  `devc mount`, and removes the `.git` mounts again in a non-git workspace.
- `devc rebuild` rebuilds the image and recreates the container. Docker reuses cached steps that haven't changed, and
  its cache is shared across projects, so steps that install the latest version of a tool only rerun with
  `--no-cache`, which is slow. Versions pinned in the `Dockerfile` (base image, Node.js and Python series, git-delta,
  fzf, Neovim, cargo-binstall) change only through Renovate.
- After a rebuild, the open Zed window shows "container is not running": reopen the project with
  **Project: Open Remote** → **Connect Dev Container**.

Ubuntu security fixes arrive with Renovate's base image updates and with `devc rebuild --no-cache`. For an urgent fix,
`sudo apt-get upgrade` in the container works until the container is recreated.

### What each command keeps

`devc down` and `devc up` stop and restart the same container. `devc rebuild` and `devc mount` create a new one.
`devc destroy` also deletes the volumes and the image.

| What                                                | `devc down`, `devc up` | `devc rebuild`       | `devc destroy`      |
| --------------------------------------------------- | ---------------------- | -------------------- | ------------------- |
| Project folder on the host, including `target/`     | Kept                   | Kept                 | Kept                |
| Volumes: shell history, Claude data, `gh` login     | Kept                   | Kept                 | **Deleted**         |
| Tools installed by hand (`apt`, `cargo install`, …) | Kept                   | **Erased**           | **Erased**          |
| Updates inside the container (`devc upgrade`, …)    | Kept                   | **Erased**           | **Erased**          |
| Caches (`~/.cargo/registry`, Neovim plugins, …)     | Kept                   | **Erased**           | **Erased**          |
| fish `set -U` variables                             | Kept                   | **Erased**           | **Erased**          |
| Running processes (tmux, servers), iptables rules   | Lost                   | Lost                 | Lost                |
| The image                                           | Kept                   | Rebuilt              | **Deleted**         |
| Zed's thread list                                   | Kept                   | Older threads hidden | Transcripts deleted |

"Claude data" is its login, settings, sessions, and memory. `post_install.py` rewrites its files, such as
`~/.gitconfig.local`, in each new container, and erased caches are downloaded again when needed. To keep a tool across
rebuilds, add it to the `Dockerfile`. For the hidden threads, see
[Known issues](#agent-threads-disappear-after-a-rebuild).

## GitHub access

Each project's `gh` login is stored in its `~/.config/gh` volume, and git uses it for HTTPS remotes on GitHub.

> [!WARNING]
> Anything in the container can read and use that token, including the code you review and its dependencies. A
> browser-flow login (`gh auth login`) or a classic token controls all your repositories, including deploy keys,
> collaborators, and webhooks that keep an attacker's access after you revoke the token. Use a
> [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) instead, or don't log in
> at all in projects with code you don't trust.

```sh
gh auth logout               # only if you're already logged in
gh auth login --with-token   # paste the token, then press Ctrl-D
gh auth status
```

Recommended token settings for your own repositories:

| Setting                                        | Value                                                |
| ---------------------------------------------- | ---------------------------------------------------- |
| Expiration                                     | 90 days or less                                      |
| Repository access                              | All repositories, or only the ones in this workspace |
| Actions                                        | Read-only (for `gh run list` and `gh run view`)      |
| Contents                                       | Read and write                                       |
| Dependabot alerts                              | Read-only                                            |
| Issues                                         | Read-only                                            |
| Metadata                                       | Read-only (required, added automatically)            |
| Pull requests                                  | Read and write                                       |
| Workflows                                      | Read and write (omit if you don't edit CI from here) |
| Administration, Deployments, Secrets, Webhooks | No access                                            |

Without **Administration**, a stolen token can't create a way back in, so revoking it ends the attacker's access; the
expiration limits forgotten copies. You can change a token's repositories and permissions later. For code you don't
trust, limit it to the repositories you need and omit **Workflows**.

`gh auth logout` doesn't invalidate a token. Delete a fine-grained token in your GitHub settings. A browser-flow login
can only be revoked by removing the **GitHub CLI** authorization (Settings → Applications), which signs out every `gh`
login, including on the host.

## Customizing the image

| Where you change it                                                         | Lasts until                |
| --------------------------------------------------------------------------- | -------------------------- |
| Inside the container, such as `devc exec sudo apt-get install -y <package>` | The container is recreated |
| The project's `.devcontainer/`, then `devc rebuild`                         | The next `devc template .` |
| Your fork of this repository                                                | Always                     |

The `Dockerfile`'s build arguments are `DOTFILES_REPO`, `NODE_VERSION`, `PYTHON_VERSION`, `NEOVIM_VERSION`,
`FZF_VERSION`, `GIT_DELTA_VERSION`, `CARGO_BINSTALL_VERSION`, and `ZSH_IN_DOCKER_VERSION`. Set them in
`devcontainer.json`:

```json
"build": {
  "dockerfile": "Dockerfile",
  "args": {
    "TZ": "${localEnv:TZ:UTC}",
    "DOTFILES_REPO": "https://github.com/<you>/dotfiles.git"
  }
}
```

To customize every project, commit your changes to a fork, point `devc` at it, then run `devc template .` and
`devc rebuild` in each project:

```sh
git -C ~/.claude-devcontainer remote set-url origin https://github.com/<you>/zed-claude-devcontainer
devc update
```

Commit to the fork, not to `~/.claude-devcontainer`: `devc update` pulls with `--ff-only`, which fails once the two
diverge. Merge this repository into your fork to get later changes.

### Extra mounts

`devc mount` shares another host folder with the container. It adds the mount to `devcontainer.json`, where
`devc template .` keeps it, and recreates the container (see [What each command keeps](#what-each-command-keeps)):

```sh
devc mount ~/drop /drop              # read-write, for passing files in and out
devc mount ~/ref /ref --readonly     # read-only; --readonly must come last
```

Code in the container can change anything in a writable mount on the host: prefer `--readonly`, and never mount broad
folders such as your home folder. Host paths can't contain commas.

### Dotfiles

The build clones `DOTFILES_REPO` and stows it into `~`:

- The repository must be cloneable over HTTPS without credentials, since the build has no SSH keys.
- It must contain `fish`, `nvim`, and `tmux` packages, laid out like your home folder (such as
  `fish/.config/fish/config.fish`); otherwise the build fails. To change the set, edit the `stow` line in the
  `Dockerfile`.
- If it has no tmux config (`~/.tmux.conf` or `~/.config/tmux/tmux.conf`), `post_install.py` writes a default one.
- An optional `claude` package is stowed into the `~/.claude` volume when the container is created. If it includes
  `settings.json`, enable `bypassPermissions` there yourself (`"permissions": {"defaultMode": "bypassPermissions"}`).
  A `settings.json` already in the volume blocks stowing the package; delete it once.
- A plain `devc rebuild` reuses the cached clone, so new commits in your dotfiles repo don't reach the image;
  `devc rebuild --no-cache` picks them up. To apply them to the running container right away, pull inside it. This
  lasts until the container is recreated. The stowed files are symlinks, so re-run `stow` only for new files:

  ```sh
  git -C ~/.dotfiles pull
  stow --no-folding -R -d ~/.dotfiles -t ~ fish nvim tmux
  ```

## Known issues

### World-writable files on the host

Some Docker engines, OrbStack among them ([orbstack/orbstack#2759](https://github.com/orbstack/orbstack/issues/2759)),
start `docker exec` processes with umask `0000`. fish and zsh restore `022` in every shell, so your terminals, Claude
Code's Bash tool (zsh), and what they run are fine; bash restores it only in interactive shells. Everything else keeps
`0000`, such as `sh -c` and non-interactive `bash -c` (including `devc exec bash -c …`), and Zed's remote server (which
saves your edits) with what it launches (language servers, `cargo check`, git), since Zed doesn't apply the shell's
umask to it ([zed-industries/zed#57185](https://github.com/zed-industries/zed/issues/57185)). Their files in the project
folder are world-writable, so other users on the host can modify them. Git doesn't record these permissions. To check
your engine, run `docker exec <container> sh -c umask`. To find and fix such files from the host (`-type` skips
symlinks, which `chmod` would follow):

```sh
find <project> \( -type f -o -type d \) -perm -0002
find <project> \( -type f -o -type d \) -perm -0002 -exec chmod go-w {} +
```

### Agent threads disappear after a rebuild

Zed only lists threads from the current container
([zed-industries/zed#56576](https://github.com/zed-industries/zed/issues/56576)), so a rebuild hides earlier threads,
and opening them from **Show Threads History** fails silently. `devc down` and `devc up` aren't affected, and the
transcripts stay in `~/.claude`. To list them again in Zed, start a thread in the new container, quit Zed, and run on
the host, replacing `<folder name>`:

```sh
DB="$HOME/Library/Application Support/Zed/db/0-stable/db.sqlite"  # Linux: ~/.local/share/zed/db/0-stable/db.sqlite
cp "$DB" "$DB.bak"
sqlite3 "$DB" "
  UPDATE sidebar_threads
  SET remote_connection = (SELECT remote_connection FROM sidebar_threads
                           WHERE folder_paths = '/workspaces/<folder name>' ORDER BY updated_at DESC LIMIT 1)
  WHERE folder_paths = '/workspaces/<folder name>';"
```

Or resume a thread in a terminal in the container. Claude Code's picker hides sessions started from Zed, so pass the
session ID (the transcript's file name under `~/.claude/projects/`), or show them with the undocumented
`CLAUDE_CODE_ENTRYPOINT` (sessions started this way are tagged like Zed's):

```sh
claude --resume <session ID>
env CLAUDE_CODE_ENTRYPOINT=sdk-ts claude --resume
```

### Zed stores the container environment in plain text

Zed's database keeps each thread's container environment, including `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`
when you pass them from the host.

## Development

The template files are at the top of this repository, so test your working copy in a scratch folder (the `devc`
command uses `~/.claude-devcontainer`):

```sh
mkdir -p ~/devc-test
git -C ~/devc-test init           # skip to test a non-git workspace
./install.sh template ~/devc-test
cd ~/devc-test
devc up
devc shell
```

After a change, run `./install.sh template ~/devc-test` again and `devc rebuild` there; to test `install.sh` itself,
run the working copy's script instead of `devc`. Clean up with `devc destroy -f`.

The `build` workflow runs on pushes and pull requests, except for changes that only touch `*.md`, `LICENSE`,
`.gitignore`, or `renovate.json`. Renovate opens one grouped pull request on Mondays and lists pending updates in its
Dependency Dashboard issue; merge the pull request once `build` passes.
