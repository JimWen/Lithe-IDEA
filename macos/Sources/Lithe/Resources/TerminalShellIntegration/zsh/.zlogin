# Forward the native user startup file, including unset versus empty ZDOTDIR.
if [[ ${LITHE_VENV_ZDOTDIR_SET-0} = 1 ]]; then
    ZDOTDIR="$LITHE_VENV_ZDOTDIR"
else
    unset ZDOTDIR
fi
if [[ -r "${ZDOTDIR-$HOME}/.zlogin" ]]; then
    builtin source "${ZDOTDIR-$HOME}/.zlogin"
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
builtin source "$LITHE_VENV_RESOURCES/activate.sh"
