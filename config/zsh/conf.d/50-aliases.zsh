# Aliases and small daily-driver helpers

if (( $+commands[eza] )); then
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -lh --git --icons=auto --group-directories-first'
    alias la='eza -lah --git --icons=auto --group-directories-first'
    alias lt='eza --tree --level=2 --icons=auto'
else
    alias ls='ls --color=auto'
    alias ll='ls -lh --color=auto'
    alias la='ls -lah --color=auto'
fi

alias grep='grep --color=auto'

# Git shortcuts
alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -n 20'
alias ga='git add'
alias gc='git commit'
alias gp='git push'

# Create directory and enter it
mkcd() {
    if [[ $# -ne 1 ]]; then
        print -u2 "Usage: mkcd <directory>"
        return 1
    fi
    mkdir -p -- "$1" && cd -- "$1"
}

# Fuzzy-find a file with fd + fzf and open it in $EDITOR
ff() {
    if ! (( $+commands[fd] && $+commands[fzf] )); then
        print -u2 "ff: requires fd and fzf"
        return 1
    fi
    local file
    if (( $+commands[bat] )); then
        file="$(fd --type f --hidden --follow --exclude .git | fzf --query="${*:-}" --preview 'bat --color=always --style=numbers --line-range=:200 {}')"
    else
        file="$(fd --type f --hidden --follow --exclude .git | fzf --query="${*:-}")"
    fi
    [[ -n "$file" ]] && "${EDITOR:-nvim}" -- "$file"
}

# Search text with rg + fzf and open the matched file/line in $EDITOR
rgf() {
    if ! (( $+commands[rg] && $+commands[fzf] )); then
        print -u2 "rgf: requires rg and fzf"
        return 1
    fi
    local match file line
    if (( $+commands[bat] )); then
        match="$(rg --line-number --no-heading --color=always --smart-case "${*:-}" | \
            fzf --ansi --delimiter=: \
                --preview 'bat --color=always --style=numbers --highlight-line {2} {1}' \
                --preview-window '+{2}/2')"
    else
        match="$(rg --line-number --no-heading --color=always --smart-case "${*:-}" | fzf --ansi --delimiter=:)"
    fi
    [[ -n "$match" ]] || return 0
    file="${match%%:*}"
    line="${match#*:}"
    line="${line%%:*}"
    if [[ -n "$file" && -n "$line" ]]; then
        "${EDITOR:-nvim}" "+$line" -- "$file"
    fi
}

# Extract common archive formats
extract() {
    if [[ $# -ne 1 || ! -f "$1" ]]; then
        print -u2 "Usage: extract <archive-file>"
        return 1
    fi
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1" ;;
        *.tar.gz|*.tgz)   tar xzf "$1" ;;
        *.tar.xz|*.txz)   tar xJf "$1" ;;
        *.tar.zst)        tar --zstd -xf "$1" ;;
        *.tar)            tar xf "$1" ;;
        *.bz2)            bunzip2 "$1" ;;
        *.gz)             gunzip "$1" ;;
        *.zip)            unzip "$1" ;;
        *.7z)
            if (( $+commands[7z] )); then
                7z x "$1"
            elif (( $+commands[7zz] )); then
                7zz x "$1"
            else
                print -u2 "extract: 7z/7zz not installed"
                return 1
            fi
            ;;
        *)
            print -u2 "extract: unsupported archive format: $1"
            return 1
            ;;
    esac
}
