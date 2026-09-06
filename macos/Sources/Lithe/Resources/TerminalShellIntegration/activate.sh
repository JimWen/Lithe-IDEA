# Product-owned activation: never source a project's activate script or use
# environment values as executable shell text. No terminal stdin is consumed.
if [[ $$ != "$LITHE_VENV_ROOT_PID" || ${ZSH_SUBSHELL-0} != 0 || ${BASH_SUBSHELL-0} != 0 || -n ${LITHE_VENV_DONE-} ]]; then
    return
fi
LITHE_VENV_DONE=1
if [[ -n ${VIRTUAL_ENV-} || -n ${_OLD_VIRTUAL_PATH+x} || -n ${_OLD_VIRTUAL_PYTHONHOME+x} ]] || builtin typeset -f deactivate >/dev/null 2>&1 || builtin alias deactivate >/dev/null 2>&1; then
    builtin printf '\033]%s;1;%s;%s;existing\007' "$LITHE_VENV_OSC" "$LITHE_VENV_NONCE" "$$"
    return
fi
if [[ $LITHE_VENV_PATH = *:* || ! -d $LITHE_VENV_PATH || ! -f $LITHE_VENV_PATH/pyvenv.cfg ]] ||
   { [[ ! -f $LITHE_VENV_PATH/bin/python || ! -x $LITHE_VENV_PATH/bin/python ]] &&
     [[ ! -f $LITHE_VENV_PATH/bin/python3 || ! -x $LITHE_VENV_PATH/bin/python3 ]]; }; then
    builtin printf '\033]%s;1;%s;%s;missing\007' "$LITHE_VENV_OSC" "$LITHE_VENV_NONCE" "$$"
    return
fi
# A readonly assignment can abort shell startup. Inspect only declaration flags,
# never parse/evaluate the declaration value. Ordinary inherited exports work.
for _lithe_venv_name in PATH VIRTUAL_ENV PYTHONHOME; do
    _lithe_venv_declaration=$(builtin typeset -p "$_lithe_venv_name" 2>/dev/null)
    _lithe_venv_flags=${_lithe_venv_declaration#* }
    _lithe_venv_flags=${_lithe_venv_flags%% *}
    case $_lithe_venv_flags in
        -*r*)
            builtin printf '\033]%s;1;%s;%s;configuration\007' "$LITHE_VENV_OSC" "$LITHE_VENV_NONCE" "$$"
            unset _lithe_venv_name _lithe_venv_flags
            return ;;
    esac
    _lithe_venv_exported=0
    case ${_lithe_venv_declaration%% *} in export) _lithe_venv_exported=1 ;; esac
    case $_lithe_venv_flags in -*x*) _lithe_venv_exported=1 ;; esac
    case $_lithe_venv_name in
        PATH) _lithe_venv_path_exported=$_lithe_venv_exported ;;
        VIRTUAL_ENV) _lithe_venv_env_exported=$_lithe_venv_exported ;;
        PYTHONHOME) _lithe_venv_home_exported=$_lithe_venv_exported ;;
    esac
done
unset _lithe_venv_name _lithe_venv_flags _lithe_venv_declaration _lithe_venv_exported
_lithe_venv_path_set=${PATH+x}
_lithe_venv_path=${PATH-}
_lithe_venv_env_set=${VIRTUAL_ENV+x}
_lithe_venv_env=${VIRTUAL_ENV-}
_lithe_venv_home_set=${PYTHONHOME+x}
_lithe_venv_home=${PYTHONHOME-}
_lithe_venv_nonce=$LITHE_VENV_NONCE
_lithe_venv_pid=$$
_lithe_venv_osc=$LITHE_VENV_OSC
# Python's standard activate replaces deactivate before reading these snapshots.
# Publishing its conventional variables lets a later manual activation leave
# this environment first, instead of retaining its bin directory in PATH.
_OLD_VIRTUAL_PATH=${PATH-}
if [[ -n ${PYTHONHOME+x} ]]; then _OLD_VIRTUAL_PYTHONHOME=$PYTHONHOME; fi
VIRTUAL_ENV="$LITHE_VENV_PATH"
PATH="$VIRTUAL_ENV/bin${PATH+:$PATH}"
unset PYTHONHOME
export PATH VIRTUAL_ENV
builtin hash -r
# This function owns only the three variables changed above. It deliberately
# leaves PS1 and user shell initialization untouched.
deactivate () {
    if [[ -n $_lithe_venv_path_set ]]; then export PATH="$_lithe_venv_path"; else unset PATH; fi
    if [[ -n $_lithe_venv_env_set ]]; then export VIRTUAL_ENV="$_lithe_venv_env"; else unset VIRTUAL_ENV; fi
    if [[ -n $_lithe_venv_home_set ]]; then export PYTHONHOME="$_lithe_venv_home"; else unset PYTHONHOME; fi
    for _lithe_venv_name in PATH VIRTUAL_ENV PYTHONHOME; do
        case $_lithe_venv_name in
            PATH) [[ -n $_lithe_venv_path_set ]] || continue; _lithe_venv_exported=$_lithe_venv_path_exported ;;
            VIRTUAL_ENV) [[ -n $_lithe_venv_env_set ]] || continue; _lithe_venv_exported=$_lithe_venv_env_exported ;;
            PYTHONHOME) [[ -n $_lithe_venv_home_set ]] || continue; _lithe_venv_exported=$_lithe_venv_home_exported ;;
        esac
        if [[ $_lithe_venv_exported = 0 ]]; then
            if [[ -n ${ZSH_VERSION-} ]]; then
                builtin typeset -g +x "$_lithe_venv_name"
            else
                builtin export -n "$_lithe_venv_name"
            fi
        fi
    done
    builtin hash -r
    if [[ $$ = "$_lithe_venv_pid" && ${ZSH_SUBSHELL-0} = 0 && ${BASH_SUBSHELL-0} = 0 ]]; then
        builtin printf '\033]%s;1;%s;%s;deactivated\007' "$_lithe_venv_osc" "$_lithe_venv_nonce" "$$"
    fi
    unset _lithe_venv_path_set _lithe_venv_path _lithe_venv_env_set _lithe_venv_env _lithe_venv_home_set _lithe_venv_home
    unset _lithe_venv_nonce _lithe_venv_pid _lithe_venv_osc
    unset _lithe_venv_path_exported _lithe_venv_env_exported _lithe_venv_home_exported _lithe_venv_name _lithe_venv_exported
    unset _OLD_VIRTUAL_PATH _OLD_VIRTUAL_PYTHONHOME
    unset -f deactivate
}
builtin printf '\033]%s;1;%s;%s;activated\007' "$LITHE_VENV_OSC" "$LITHE_VENV_NONCE" "$$"
