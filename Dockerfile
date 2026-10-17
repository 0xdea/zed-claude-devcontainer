# Claude Code Devcontainer
# Based on Microsoft devcontainer image for better devcontainer integration
# Modified by raptor, 2026: Zed support.
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

# Rename the base image's vscode user (UID/GID 1000, passwordless sudo) to zed
RUN groupmod -n zed vscode && \
  usermod -l zed -d /home/zed -m vscode && \
  mv /etc/sudoers.d/vscode /etc/sudoers.d/zed && \
  sed -i 's/^vscode /zed /' /etc/sudoers.d/zed && \
  sed -i 's/^vscode:/zed:/' /etc/subuid /etc/subgid

# Create directories and set ownership (combined for fewer layers)
RUN mkdir -p /commandhistory /workspace /home/zed/.claude /opt && \
  touch /commandhistory/.bash_history && \
  touch /commandhistory/.zsh_history && \
  mkdir -p /commandhistory/fish && \
  chown -R zed:zed /commandhistory /workspace /home/zed/.claude /opt

# System-wide shell init: Zed launches processes via docker exec with umask 0000,
# so restore a sane umask; also add cargo bin to PATH for shells (ENV PATH below
# covers non-shell processes)
RUN printf '%s\n' \
    '# devcontainer: restore sane umask (docker exec from Zed starts with 0000)' \
    'umask 022' \
    '# devcontainer: cargo/rustup binaries' \
    'case ":$PATH:" in *":/home/zed/.cargo/bin:"*) ;; *) export PATH="/home/zed/.cargo/bin:$PATH" ;; esac' \
    | tee -a /etc/zsh/zshenv /etc/bash.bashrc >/dev/null && \
  mkdir -p /etc/fish/conf.d && \
  printf '%s\n' \
    '# devcontainer: restore sane umask (docker exec from Zed starts with 0000)' \
    'umask 022' \
    '# devcontainer: cargo/rustup binaries' \
    'fish_add_path -g /home/zed/.cargo/bin' \
    > /etc/fish/conf.d/container-env.fish

# Make fish the login shell
RUN usermod -s /usr/bin/fish zed

# Set environment variables
ENV DEVCONTAINER=true
ENV SHELL=/usr/bin/fish
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspace

# Switch to non-root user for remaining setup
USER zed

# Set PATH early so claude and other user-installed binaries are available
ENV PATH="/home/zed/.local/bin:$PATH"

# Install Claude Code natively with marketplace plugins
RUN curl -fsSL https://claude.ai/install.sh | bash && \
  claude plugin marketplace add anthropics/skills && \
  claude plugin marketplace add trailofbits/skills && \
  claude plugin marketplace add trailofbits/skills-curated

# Install Python 3.13 via uv (fast binary download, not source compilation)
RUN uv python install 3.13 --default

# Install ast-grep (AST-based code search)
RUN uv tool install ast-grep-cli

# Install fnm (Fast Node Manager) and Node
ARG NODE_VERSION=24
ENV FNM_DIR="/home/zed/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  export PATH="$FNM_DIR:$PATH" && \
  eval "$(fnm env)" && \
  fnm install ${NODE_VERSION} && \
  fnm default ${NODE_VERSION}

# fnm's shell hook is zsh-only, so without this node/npm are missing from bash/sh
ENV PATH="$FNM_DIR/aliases/default/bin:$PATH"

# Install Rust via rustup (stable, minimal profile + common components)
ENV RUSTUP_HOME="/home/zed/.rustup" \
  CARGO_HOME="/home/zed/.cargo"
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | \
  sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
    --component rustfmt,clippy,rust-analyzer

# Set via ENV (like fnm) so cargo works in bash, zsh and fish
ENV PATH="$CARGO_HOME/bin:$PATH"

# Install Oh My Zsh
# renovate: datasource=github-releases depName=deluan/zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -x

# Copy zsh configuration
COPY --chown=zed:zed .zshrc /home/zed/.zshrc.custom

# Append custom zshrc to the main one
RUN echo 'source ~/.zshrc.custom' >> /home/zed/.zshrc

# Install dotfiles with GNU Stow (--no-folding so tools don't write into the repo)
# The claude package is stowed by post_install.py, since ~/.claude is a volume mounted at runtime
ARG DOTFILES_REPO=https://github.com/0xdea/dotfiles.git
RUN git clone "$DOTFILES_REPO" /home/zed/.dotfiles && \
  stow --no-folding -d /home/zed/.dotfiles -t /home/zed fish nvim tmux

# Copy fish configuration
COPY --chown=zed:zed devcontainer.fish /home/zed/.config/fish/conf.d/devcontainer.fish

# Keep fish history on the /commandhistory volume (directory symlink, since fish
# replaces the history file atomically)
RUN mkdir -p /home/zed/.local/share && \
  ln -s /commandhistory/fish /home/zed/.local/share/fish

# Copy post_install script
COPY --chown=zed:zed post_install.py /opt/post_install.py
