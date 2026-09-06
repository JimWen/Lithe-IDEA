# Called once from the original scalar PROMPT_COMMAND, after native login rc.
if [[ $$ != "$LITHE_VENV_ROOT_PID" || ${BASH_SUBSHELL-0} != 0 || -n ${LITHE_VENV_DONE-} ]]; then
    return
fi
if [[ ${PROMPT_COMMAND-} != "$LITHE_VENV_EXPECTED_PROMPT" ]]; then
    LITHE_VENV_DONE=1
    builtin printf '\033]%s;1;%s;%s;configuration\007' "$LITHE_VENV_OSC" "$LITHE_VENV_NONCE" "$$"
    return
fi
if [[ $LITHE_VENV_PROMPT_SET = 1 ]]; then
    PROMPT_COMMAND="$LITHE_VENV_PROMPT"
else
    unset PROMPT_COMMAND
fi
builtin source "$LITHE_VENV_RESOURCES/activate.sh"
