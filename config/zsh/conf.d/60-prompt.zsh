# Prompt: Starship if installed, otherwise clean native vcs_info git prompt
if (( $+commands[starship] )); then
    eval "$(starship init zsh)"
else
    autoload -Uz vcs_info add-zsh-hook
    setopt PROMPT_SUBST
    zstyle ':vcs_info:*' enable git
    zstyle ':vcs_info:git:*' formats ' %F{magenta}(%b)%f'
    zstyle ':vcs_info:git:*' actionformats ' %F{magenta}(%b|%a)%f'
    add-zsh-hook precmd vcs_info

    PROMPT='%F{blue}%~%f${vcs_info_msg_0_} %(?.%F{green}❯%f.%F{red}❯%f) '
fi
