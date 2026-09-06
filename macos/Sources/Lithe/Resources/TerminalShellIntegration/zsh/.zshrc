# Forward the native user startup file, including unset versus empty ZDOTDIR.
if [[ ${LITHE_VENV_ZDOTDIR_SET-0} = 1 ]]; then
    ZDOTDIR="$LITHE_VENV_ZDOTDIR"
else
    unset ZDOTDIR
fi
# macOS /etc/zshrc derives its default history path before this forwarding
# file runs. Redirect only that derived default; user rc can still replace it.
if [[ ${HISTFILE-} = "$LITHE_VENV_RESOURCES/zsh/.zsh_history" ]]; then
    HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
fi
if [[ -r "${ZDOTDIR-$HOME}/.zshrc" ]]; then
    builtin source "${ZDOTDIR-$HOME}/.zshrc"
fi
if (( ${+ZDOTDIR} )); then
    LITHE_VENV_ZDOTDIR_SET=1
    LITHE_VENV_ZDOTDIR="$ZDOTDIR"
else
    LITHE_VENV_ZDOTDIR_SET=0
    LITHE_VENV_ZDOTDIR=""
fi
if [[ $$ != "$LITHE_VENV_ROOT_PID" || ${ZSH_SUBSHELL-0} != 0 ]]; then
    return
fi
# Respect user startup choices and leave their final ZDOTDIR in place.
if [[ ! -o rcs ]]; then
    return
fi
if [[ -o login ]]; then
    ZDOTDIR="$LITHE_VENV_RESOURCES/zsh"
else
    builtin source "$LITHE_VENV_RESOURCES/activate.sh"
fi
