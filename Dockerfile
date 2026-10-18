# Claude Code Devcontainer
# Based on Microsoft devcontainer image for better devcontainer integration
FROM ghcr.io/astral-sh/uv:0.10@sha256:10902f58a1606787602f303954cea099626a4adb02acbac4c69920fe9d278f82 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:4bcb1b466771b1ba1ea110e2a27daea2f6093f9527fb75ee59703ec89b5561cb

ARG TZ
ENV TZ="$TZ"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install additional system packages (base image already includes git, curl, sudo, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
  # Sandboxing support for Claude Code
  bubblewrap \
  socat \
  # Modern CLI tools
  fd-find \
  ripgrep \
  tmux \
  zsh \
  fish \
  # Build tools
  build-essential \
  # GUI/automation deps (jiggy: mouse-rs needs libxdo, tests need a virtual X display)
  libxdo-dev \
  xvfb \
  # Utilities
  jq \
  nano \
  stow \
  unzip \
  vim \
  # Network tools (for security testing)
  dnsutils \
  ipset \
  iptables \
  iproute2 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install git-delta
# renovate: datasource=github-releases depName=dandavison/delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && \
  rm /tmp/git-delta.deb

# Install uv (Python package manager) via multi-stage copy
COPY --from=uv /uv /usr/local/bin/uv

# Install fzf from GitHub releases (newer than apt, includes built-in shell integration)
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.70.0
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in \
    amd64) FZF_ARCH="linux_amd64" ;; \
    arm64) FZF_ARCH="linux_arm64" ;; \
    *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
  esac && \
  curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz" | tar -xz -C /usr/local/bin

# Install Neovim from GitHub releases (apt's 0.9.x is too old for current lazy.nvim)
# renovate: datasource=github-releases depName=neovim/neovim
ARG NEOVIM_VERSION=0.12.6
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in \
    amd64) NVIM_ARCH="x86_64" ;; \
    arm64) NVIM_ARCH="arm64" ;; \
    *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
  esac && \
  mkdir -p /usr/local/lib/nvim && \
  curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz" | \
    tar -xz -C /usr/local/lib/nvim --strip-components=1 && \
  ln -s /usr/local/lib/nvim/bin/nvim /usr/local/bin/nvim

# Create directories and set ownership (combined for fewer layers)
RUN mkdir -p /commandhistory /workspaces /home/vscode/.claude /opt && \
  touch /commandhistory/.bash_history && \
  touch /commandhistory/.zsh_history && \
  mkdir -p /commandhistory/fish && \
  chown -R vscode:vscode /commandhistory /workspaces /home/vscode/.claude /opt

# System-wide shell init: some engines (e.g. OrbStack) start docker exec processes,
# such as Zed's, with umask 0000, so restore a sane umask; also add cargo bin to PATH
# for shells (ENV PATH below covers non-shell processes)
RUN printf '%s\n' \
    '# devcontainer: restore sane umask (docker exec gets 0000 on some engines)' \
    'umask 022' \
    '# devcontainer: cargo/rustup binaries' \
    'case ":$PATH:" in *":/home/vscode/.cargo/bin:"*) ;; *) export PATH="/home/vscode/.cargo/bin:$PATH" ;; esac' \
    | tee -a /etc/zsh/zshenv /etc/bash.bashrc >/dev/null && \
  mkdir -p /etc/fish/conf.d && \
  printf '%s\n' \
    '# devcontainer: restore sane umask (docker exec gets 0000 on some engines)' \
    'umask 022' \
    '# devcontainer: cargo/rustup binaries' \
    'fish_add_path -g /home/vscode/.cargo/bin' \
    > /etc/fish/conf.d/container-env.fish

# Make fish the login shell
RUN usermod -s /usr/bin/fish vscode

# Set environment variables
ENV DEVCONTAINER=true
ENV SHELL=/usr/bin/fish
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspaces

# Switch to non-root user for remaining setup
USER vscode

# Set PATH early so claude and other user-installed binaries are available
ENV PATH="/home/vscode/.local/bin:$PATH"

# Install Claude Code natively with marketplace plugins
RUN curl -fsSL https://claude.ai/install.sh | bash && \
  claude plugin marketplace add anthropics/skills && \
  claude plugin marketplace add trailofbits/skills && \
  claude plugin marketplace add trailofbits/skills-curated

# Install Python 3.13 via uv (fast binary download, not source compilation)
RUN uv python install 3.13 --default

# Install ast-grep (AST-based code search) and zizmor (GitHub Actions security linter)
RUN uv tool install ast-grep-cli && \
  uv tool install zizmor

# Install fnm (Fast Node Manager) and Node
ARG NODE_VERSION=24
ENV FNM_DIR="/home/vscode/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  export PATH="$FNM_DIR:$PATH" && \
  eval "$(fnm env)" && \
  fnm install ${NODE_VERSION} && \
  fnm default ${NODE_VERSION}

# fnm's shell hook is zsh-only, so without this node/npm are missing from bash/sh
ENV PATH="$FNM_DIR/aliases/default/bin:$PATH"

# Install Rust via rustup (stable, minimal profile + common components, wasm32-wasip2
# target for Zed extensions)
ENV RUSTUP_HOME="/home/vscode/.rustup" \
  CARGO_HOME="/home/vscode/.cargo"
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | \
  sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
    --component rustfmt,clippy,rust-analyzer --target wasm32-wasip2

# Set via ENV (like fnm) so cargo works in bash, zsh and fish
ENV PATH="$CARGO_HOME/bin:$PATH"

# Install cargo tools with cargo-binstall: each project's own release binaries, falling
# back to compiling from crates.io (no QuickInstall third-party builds or statistics,
# and no GitHub token lookup)
# renovate: datasource=github-releases depName=cargo-bins/cargo-binstall
ARG CARGO_BINSTALL_VERSION=1.25.3
RUN curl -fsSL "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}/cargo-binstall-$(uname -m)-unknown-linux-musl.tgz" | \
    tar -xz -C "$CARGO_HOME/bin" && \
  cargo binstall -y --locked --strategies crate-meta-data,compile --disable-telemetry --no-discover-github-token \
    cargo-audit cargo-deny cargo-semver-checks cargo-nextest cargo-generate cargo-dylint dylint-link

# Install Oh My Zsh
# renovate: datasource=github-releases depName=deluan/zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -x

# Copy zsh configuration
COPY --chown=vscode:vscode .zshrc /home/vscode/.zshrc.custom

# Append custom zshrc to the main one
RUN echo 'source ~/.zshrc.custom' >> /home/vscode/.zshrc

# Install dotfiles with GNU Stow (--no-folding so tools don't write into the repo)
# The claude package is stowed by post_install.py, since ~/.claude is a volume mounted at runtime
ARG DOTFILES_REPO=https://github.com/0xdea/dotfiles.git
RUN git clone "$DOTFILES_REPO" /home/vscode/.dotfiles && \
  stow --no-folding -d /home/vscode/.dotfiles -t /home/vscode fish nvim tmux

# Copy fish configuration
COPY --chown=vscode:vscode devcontainer.fish /home/vscode/.config/fish/conf.d/devcontainer.fish

# Keep fish history on the /commandhistory volume (directory symlink, since fish
# replaces the history file atomically)
RUN mkdir -p /home/vscode/.local/share && \
  ln -s /commandhistory/fish /home/vscode/.local/share/fish

# Copy post_install script
COPY --chown=vscode:vscode post_install.py /opt/post_install.py
