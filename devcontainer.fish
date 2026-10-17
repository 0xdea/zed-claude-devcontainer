# Fish configuration for Claude Code devcontainer
# (fish counterpart of .zshrc; PATH for ~/.local/bin, fnm and cargo is set via ENV)

# Aliases
alias fd fdfind
alias sg ast-grep
alias claude-yolo 'claude --dangerously-skip-permissions'
alias ll 'ls -lah --color=auto'
alias la 'ls -A --color=auto'
alias l 'ls -CF --color=auto'

# fzf configuration - use fd for faster file finding
set -gx FZF_DEFAULT_COMMAND 'fdfind --type f --hidden --follow --exclude .git'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
set -gx FZF_ALT_C_COMMAND 'fdfind --type d --hidden --follow --exclude .git'
set -gx FZF_DEFAULT_OPTS '--height 40% --layout=reverse --border --info=inline'

if status is-interactive
    # Source fzf shell integration (built-in since fzf 0.48+)
    fzf --fish | source
end
