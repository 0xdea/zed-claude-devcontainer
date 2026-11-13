# zed-claude-devcontainer

Fork of trailofbits/claude-code-devcontainer: a Zed-focused dev container for Claude Code, managed by `devc`
(`install.sh`). The README documents behaviour; keep it in sync with every user-visible change.

## Files

- `install.sh`: the `devc` CLI. `devc template .` copies `Dockerfile`, `devcontainer.json`, `post_install.py`, `.zshrc`,
  and `devcontainer.fish` into a project's `.devcontainer/`, keeping `devc mount` mounts and the `--cap-add=NET_RAW`
  opt-in.
- `post_install.py`: runs in the container after creation (`postCreateCommand`).
- `renovate.json`: pinned versions update with a 10-day minimum release age; unpinned tools follow the same rule
  (`UV_EXCLUDE_NEWER`, npm `--before`).

## Conventions

- `install.sh` must run on macOS's bash 3.2: no `mapfile` or associative arrays; expand possibly empty arrays as
  `${arr[@]+"${arr[@]}"}`.
- The helper scripts embedded in `install.sh` (`NET_RESOLVE_SCRIPT`, `NET_APPLY_SCRIPT`) are single-quoted: write a
  single quote as `'\''`, and keep apostrophes out of their comments. The same goes for the single-quoted scripts in
  `.github/workflows/build.yml`.
- `devcontainer.json` must stay plain JSON (no comments or trailing commas): `devc` edits it with jq.
- README: terse, wrapped at 120 columns. Update "What each command keeps" and "About this fork" when behaviour changes.
- New tools or features get a check in CI's "check container" step (one `command -v` per tool: with several names it
  succeeds if any is found).

## Security model

Code in the container, including Claude and dependencies, is treated as hostile. `.devcontainer`, `.git/config`, and
`.git/hooks` are mounted read-only. The container gets neither `NET_ADMIN` nor `NET_RAW`, which `devc net lock` relies
on: its nftables rules are set from a helper container, and raw sockets (`AF_PACKET`, `AF_XDP`) would skip them. Data
from the container's side (its `/etc/hosts`, `resolv.conf`, files in the workspace) must never decide what the lock
allows; addresses passed to nft must match `NET_IPV4_RE`.

## Checks and testing

- Lint like CI: `jq -e . devcontainer.json`; `shellcheck -S warning install.sh .zshrc`; `ruff check` and
  `ruff format --check` on `post_install.py`; `hadolint --failure-threshold warning --ignore DL3008 - < Dockerfile`.
  On the Mac, shellcheck and hadolint aren't installed: run them with Docker (`koalaman/shellcheck:stable`,
  `hadolint/hadolint`).
- Try changes in throwaway containers from an existing `vsc-` image, or in a scratch project under `$HOME`. Not under
  `/tmp`, which is a symlink on macOS: `devc` finds containers by the physical path.
- Before rebuilding a scratch project, run `./install.sh template .` there. Builds outside fish need
  `DEVC_DOTFILES_REPO` from the user's environment.
- The full image build is slow: test packages and behaviour in a plain container first, and let CI build both
  architectures.
