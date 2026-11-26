# Optional modern CLI integrations (all guarded so minimal profile runs cleanly)

if (( $+commands[fzf] )); then
    export FZF_DEFAULT_OPTS="--color=16 --height=40% --layout=reverse --border"
    if (( $+commands[fd] )); then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi
    if (( $+commands[bat] )); then
        export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:200 {}'"
    fi
    source <(fzf --zsh)
fi

if (( $+commands[zoxide] )); then
    eval "$(zoxide init zsh)"
fi

if (( $+commands[bat] )); then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT="-c"
fi

if (( $+commands[yazi] )); then
    function y() {
        local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
        yazi "$@" --cwd-file="$tmp"
        if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
            builtin cd -- "$cwd"
        fi
        rm -f -- "$tmp"
    }
fi

if [[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
