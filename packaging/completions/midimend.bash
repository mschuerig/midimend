_midimend() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local prev=${COMP_WORDS[COMP_CWORD-1]}
    case $prev in
        --init)
            COMPREPLY=($(compgen -o plusdirs -f -X '!*.js' -- "$cur"))
            return
            ;;
    esac
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W '--help --list-devices --init' -- "$cur"))
    else
        COMPREPLY=($(compgen -o plusdirs -f -X '!*.json' -- "$cur"))
    fi
}
complete -F _midimend midimend
