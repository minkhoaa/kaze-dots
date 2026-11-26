# Keybindings (Emacs mode + prefix history search + Foot/xterm navigation)
bindkey -e

autoload -Uz up-line-or-beginning-search down-line-or-beginning-search edit-command-line
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
zle -N edit-command-line

[[ -n "${terminfo[khome]:-}" ]] && bindkey "${terminfo[khome]}" beginning-of-line
[[ -n "${terminfo[kend]:-}"  ]] && bindkey "${terminfo[kend]}"  end-of-line
[[ -n "${terminfo[kdch1]:-}" ]] && bindkey "${terminfo[kdch1]}" delete-char
[[ -n "${terminfo[kcuu1]:-}" ]] && bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
[[ -n "${terminfo[kcud1]:-}" ]] && bindkey "${terminfo[kcud1]}" down-line-or-beginning-search

bindkey '^[[H'       beginning-of-line
bindkey '^[OH'       beginning-of-line
bindkey '^[[F'       end-of-line
bindkey '^[OF'       end-of-line
bindkey '^[[3~'      delete-char
bindkey '^[[A'       up-line-or-beginning-search
bindkey '^[[B'       down-line-or-beginning-search
bindkey '^[[1;5C'    forward-word
bindkey '^[[1;5D'    backward-word
bindkey '^H'         backward-kill-word
bindkey '^[[127;5u'  backward-kill-word
bindkey '^[^?'       backward-kill-word
bindkey '^[^H'       backward-kill-word
bindkey '^X^E'       edit-command-line

# Foot terminal integration: OSC 7 (CWD) and OSC 133 (prompt jump markers)
_kaze_foot_precmd() {
    print -Pn "\e]133;A\e\\"
    if [[ "$TERM" == foot* ]]; then
        local encoded_pwd="${PWD// /%20}"
        printf '\e]7;file://%s%s\e\\' "${HOST}" "${encoded_pwd}"
    fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _kaze_foot_precmd
