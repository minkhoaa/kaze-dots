# Completion (includes Arch extra/zsh-completions when installed)
if [[ -d /usr/share/zsh/site-functions ]]; then
    fpath=(/usr/share/zsh/site-functions $fpath)
fi

[[ -o extendedglob ]] || setopt EXTENDED_GLOB

autoload -Uz compinit
: "${XDG_CACHE_HOME:=$HOME/.cache}"
local dump="$XDG_CACHE_HOME/zsh/zcompdump"
if [[ -n "$dump"(#qN.mh+24) || ! -f "$dump" ]]; then
    compinit -d "$dump"
else
    compinit -C -d "$dump"
fi
unset dump

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- no matches found --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/zcompcache"
