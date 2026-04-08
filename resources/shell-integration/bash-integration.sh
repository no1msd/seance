# seance shell integration for bash
# Source this from your .bashrc:
#   [[ -n "$SEANCE_SHELL_INTEGRATION_DIR" ]] && source "$SEANCE_SHELL_INTEGRATION_DIR/bash-integration.sh"

# Guard: only run inside seance
[[ -z "$SEANCE_SOCKET_PATH" ]] && return 2>/dev/null || true
[[ -z "$SEANCE_PANEL_ID" ]] && return 2>/dev/null || true

# Prepend seance bin dir to PATH (for claude wrapper, etc.)
[[ -n "$SEANCE_BIN_DIR" && -d "$SEANCE_BIN_DIR" ]] && export PATH="$SEANCE_BIN_DIR:$PATH"

# Restore scrollback from previous session (runs once at shell startup)
_seance_restore_scrollback_once() {
    local path="${SEANCE_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset SEANCE_RESTORE_SCROLLBACK_FILE
    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        command rm -f -- "$path" 2>/dev/null || true
    fi
}
_seance_restore_scrollback_once
unset -f _seance_restore_scrollback_once 2>/dev/null

_seance_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -w 1 -U "$SEANCE_SOCKET_PATH" --send-only 2>/dev/null
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$SEANCE_SOCKET_PATH" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        if printf '%s\n' "$payload" | nc -N -U "$SEANCE_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$SEANCE_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Throttle heavy work to avoid prompt latency.
_SEANCE_GIT_LAST_PWD="${_SEANCE_GIT_LAST_PWD:-}"
_SEANCE_GIT_LAST_RUN="${_SEANCE_GIT_LAST_RUN:-0}"
_SEANCE_GIT_JOB_PID="${_SEANCE_GIT_JOB_PID:-}"
_SEANCE_GIT_JOB_STARTED_AT="${_SEANCE_GIT_JOB_STARTED_AT:-0}"
_SEANCE_GIT_FORCE="${_SEANCE_GIT_FORCE:-0}"
_SEANCE_GIT_HEAD_LAST_PWD="${_SEANCE_GIT_HEAD_LAST_PWD:-}"
_SEANCE_GIT_HEAD_PATH="${_SEANCE_GIT_HEAD_PATH:-}"
_SEANCE_GIT_HEAD_SIGNATURE="${_SEANCE_GIT_HEAD_SIGNATURE:-}"
_SEANCE_ASYNC_JOB_TIMEOUT="${_SEANCE_ASYNC_JOB_TIMEOUT:-20}"

_seance_git_resolve_head_path() {
    local dir="$PWD"
    while :; do
        if [[ -d "$dir/.git" ]]; then
            printf '%s\n' "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            IFS= read -r line < "$dir/.git" || line=""
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                printf '%s\n' "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir%/*}"
        [[ -z "$dir" ]] && dir="/"
    done
    return 1
}

_seance_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line
    IFS= read -r line < "$head_path" || return 1
    printf '%s\n' "$line"
}

_seance_preexec_command() {
    [[ -S "$SEANCE_SOCKET_PATH" ]] || return 0
    [[ -n "$SEANCE_PANE_GROUP_ID" ]] || return 0
    [[ -n "$SEANCE_PANEL_ID" ]] || return 0

    # Heuristic: commands that may change git state without changing $PWD.
    local cmd="${BASH_COMMAND## }"
    case "$cmd" in
        git\ *|git|gh\ *|lazygit|lazygit\ *|tig|tig\ *|gitui|gitui\ *|stg\ *|jj\ *)
            _SEANCE_GIT_FORCE=1 ;;
    esac
}

_seance_bash_preexec_hook() {
    _seance_preexec_command
}

_seance_prompt_command() {
    [[ -S "$SEANCE_SOCKET_PATH" ]] || return 0
    [[ -n "$SEANCE_PANE_GROUP_ID" ]] || return 0
    [[ -n "$SEANCE_PANEL_ID" ]] || return 0

    # CWD reporting is handled by ghostty's built-in shell integration
    # (OSC 7) — no need to duplicate it here.

    local now=$SECONDS
    local pwd="$PWD"

    # Post-wake: clear stale git probe.
    if [[ -n "$_SEANCE_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_SEANCE_GIT_JOB_PID" 2>/dev/null; then
            _SEANCE_GIT_JOB_PID=""
            _SEANCE_GIT_JOB_STARTED_AT=0
        elif (( _SEANCE_ASYNC_JOB_TIMEOUT > 0 )) && (( now - _SEANCE_GIT_JOB_STARTED_AT >= _SEANCE_ASYNC_JOB_TIMEOUT )); then
            _SEANCE_GIT_JOB_PID=""
            _SEANCE_GIT_JOB_STARTED_AT=0
            _SEANCE_GIT_FORCE=1
        fi
    fi

    # Track .git/HEAD to detect branch changes from aliases/tools.
    local git_head_changed=0
    if [[ "$pwd" != "$_SEANCE_GIT_HEAD_LAST_PWD" ]]; then
        _SEANCE_GIT_HEAD_LAST_PWD="$pwd"
        _SEANCE_GIT_HEAD_PATH="$(_seance_git_resolve_head_path 2>/dev/null || true)"
        _SEANCE_GIT_HEAD_SIGNATURE=""
    fi
    if [[ -n "$_SEANCE_GIT_HEAD_PATH" ]]; then
        local head_signature
        head_signature="$(_seance_git_head_signature "$_SEANCE_GIT_HEAD_PATH" 2>/dev/null || true)"
        if [[ -n "$head_signature" && "$head_signature" != "$_SEANCE_GIT_HEAD_SIGNATURE" ]]; then
            _SEANCE_GIT_HEAD_SIGNATURE="$head_signature"
            git_head_changed=1
            _SEANCE_GIT_FORCE=1
        fi
    fi

    # Git branch/dirty: async, deduped by running-job check.
    # Kill stale probe when pwd changes or HEAD changed.
    if [[ -n "$_SEANCE_GIT_JOB_PID" ]] && kill -0 "$_SEANCE_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_SEANCE_GIT_LAST_PWD" || "$git_head_changed" == "1" ]]; then
            kill "$_SEANCE_GIT_JOB_PID" >/dev/null 2>&1 || true
            _SEANCE_GIT_JOB_PID=""
            _SEANCE_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ -z "$_SEANCE_GIT_JOB_PID" ]] || ! kill -0 "$_SEANCE_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_SEANCE_GIT_LAST_PWD" ]] || (( _SEANCE_GIT_FORCE )) || (( now - _SEANCE_GIT_LAST_RUN >= 3 )); then
            _SEANCE_GIT_FORCE=0
            _SEANCE_GIT_LAST_PWD="$pwd"
            _SEANCE_GIT_LAST_RUN=$now
            {
                local branch dirty_json=""
                branch=$(git branch --show-current 2>/dev/null)
                branch="${branch//\"/\\\"}"
                if [[ -n "$branch" ]]; then
                    local first
                    first=$(git status --porcelain -uno 2>/dev/null | head -1)
                    [[ -n "$first" ]] && dirty_json=',"dirty":true'
                    _seance_send "{\"id\":\"1\",\"method\":\"surface.report_git\",\"params\":{\"surface_id\":$SEANCE_PANEL_ID,\"branch\":\"$branch\"$dirty_json}}"
                else
                    _seance_send "{\"id\":\"1\",\"method\":\"surface.clear_git\",\"params\":{\"surface_id\":$SEANCE_PANEL_ID}}"
                fi
            } >/dev/null 2>&1 &
            _SEANCE_GIT_JOB_PID=$!
            disown
            _SEANCE_GIT_JOB_STARTED_AT=$now
        fi
    fi
}

_seance_install_prompt_command() {
    [[ -n "${_SEANCE_PROMPT_INSTALLED:-}" ]] && return 0
    _SEANCE_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_seance_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_seance_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_seance_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_seance_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_seance_prompt_command"
                fi
                ;;
        esac
    fi

    # Bash 4.4+ preexec via PS0
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
            builtin readonly _SEANCE_BASH_PS0='${ _seance_bash_preexec_hook; }'
        else
            builtin readonly _SEANCE_BASH_PS0='$(_seance_bash_preexec_hook >/dev/null)'
        fi
        if [[ "$PS0" != *"${_SEANCE_BASH_PS0}"* ]]; then
            PS0=$PS0"${_SEANCE_BASH_PS0}"
        fi
    fi
}

_seance_install_prompt_command
