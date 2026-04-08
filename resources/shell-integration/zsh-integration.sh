# seance shell integration for zsh
# Source this from your .zshrc:
#   [[ -n "$SEANCE_SHELL_INTEGRATION_DIR" ]] && source "$SEANCE_SHELL_INTEGRATION_DIR/zsh-integration.sh"

# Guard: only run inside seance
[[ -z "$SEANCE_SOCKET_PATH" ]] && return
[[ -z "$SEANCE_PANEL_ID" ]] && return

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
unfunction _seance_restore_scrollback_once 2>/dev/null

_seance_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        print -r -- "$payload" | ncat -w 1 -U "$SEANCE_SOCKET_PATH" --send-only 2>/dev/null
    elif command -v socat >/dev/null 2>&1; then
        print -r -- "$payload" | socat -T 1 - "UNIX-CONNECT:$SEANCE_SOCKET_PATH" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        if print -r -- "$payload" | nc -N -U "$SEANCE_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            print -r -- "$payload" | nc -w 1 -U "$SEANCE_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Throttle heavy work to avoid prompt latency.
typeset -g _SEANCE_GIT_LAST_PWD=""
typeset -g _SEANCE_GIT_LAST_RUN=0
typeset -g _SEANCE_GIT_JOB_PID=""
typeset -g _SEANCE_GIT_JOB_STARTED_AT=0
typeset -g _SEANCE_GIT_FORCE=0
typeset -g _SEANCE_GIT_HEAD_LAST_PWD=""
typeset -g _SEANCE_GIT_HEAD_PATH=""
typeset -g _SEANCE_GIT_HEAD_SIGNATURE=""
typeset -g _SEANCE_ASYNC_JOB_TIMEOUT=20

_seance_git_resolve_head_path() {
    local dir="$PWD"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            print -r -- "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                print -r -- "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_seance_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line=""
    if IFS= read -r line < "$head_path"; then
        print -r -- "$line"
        return 0
    fi
    return 1
}

_seance_report_git_branch_for_path() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || return 0
    [[ -S "$SEANCE_SOCKET_PATH" ]] || return 0
    [[ -n "$SEANCE_PANE_GROUP_ID" ]] || return 0
    [[ -n "$SEANCE_PANEL_ID" ]] || return 0

    local branch dirty_json="" first
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    branch="${branch//\"/\\\"}"
    if [[ -n "$branch" ]]; then
        first="$(git -C "$repo_path" status --porcelain -uno 2>/dev/null | head -1)"
        [[ -n "$first" ]] && dirty_json=',"dirty":true'
        _seance_send "{\"id\":\"1\",\"method\":\"surface.report_git\",\"params\":{\"surface_id\":$SEANCE_PANEL_ID,\"branch\":\"$branch\"$dirty_json}}"
    else
        _seance_send "{\"id\":\"1\",\"method\":\"surface.clear_git\",\"params\":{\"surface_id\":$SEANCE_PANEL_ID}}"
    fi
}

_seance_preexec() {
    # Heuristic: commands that may change git state without changing $PWD.
    local cmd="${1## }"
    case "$cmd" in
        git\ *|git|gh\ *|lazygit|lazygit\ *|tig|tig\ *|gitui|gitui\ *|stg\ *|jj\ *)
            _SEANCE_GIT_FORCE=1 ;;
    esac
}

_seance_precmd() {
    [[ -S "$SEANCE_SOCKET_PATH" ]] || return 0
    [[ -n "$SEANCE_PANE_GROUP_ID" ]] || return 0
    [[ -n "$SEANCE_PANEL_ID" ]] || return 0

    # CWD reporting is handled by ghostty's built-in shell integration
    # (OSC 7) — no need to duplicate it here.

    local now=$EPOCHSECONDS
    local pwd="$PWD"

    # Post-wake: clear stale git probe.
    if [[ -n "$_SEANCE_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_SEANCE_GIT_JOB_PID" 2>/dev/null; then
            _SEANCE_GIT_JOB_PID=""
            _SEANCE_GIT_JOB_STARTED_AT=0
        elif (( _SEANCE_GIT_JOB_STARTED_AT > 0 )) && (( now - _SEANCE_GIT_JOB_STARTED_AT >= _SEANCE_ASYNC_JOB_TIMEOUT )); then
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

    # Git branch/dirty: async, deduped.
    local should_git=0
    if [[ "$pwd" != "$_SEANCE_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _SEANCE_GIT_FORCE )); then
        should_git=1
    elif (( now - _SEANCE_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if (( should_git )); then
        local can_launch_git=1
        if [[ -n "$_SEANCE_GIT_JOB_PID" ]] && kill -0 "$_SEANCE_GIT_JOB_PID" 2>/dev/null; then
            if [[ "$pwd" != "$_SEANCE_GIT_LAST_PWD" ]] || (( _SEANCE_GIT_FORCE )); then
                kill "$_SEANCE_GIT_JOB_PID" >/dev/null 2>&1 || true
                _SEANCE_GIT_JOB_PID=""
                _SEANCE_GIT_JOB_STARTED_AT=0
            else
                can_launch_git=0
            fi
        fi

        if (( can_launch_git )); then
            _SEANCE_GIT_FORCE=0
            _SEANCE_GIT_LAST_PWD="$pwd"
            _SEANCE_GIT_LAST_RUN=$now
            {
                _seance_report_git_branch_for_path "$pwd"
            } >/dev/null 2>&1 &!
            _SEANCE_GIT_JOB_PID=$!
            _SEANCE_GIT_JOB_STARTED_AT=$now
        fi
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _seance_preexec
add-zsh-hook precmd _seance_precmd
