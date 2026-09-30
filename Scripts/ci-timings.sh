# Optional spans around shell-owned commands/functions. This deliberately does not wrap the
# command in `if`, disable errexit, redirect its output, or launch another process owner.
spotty_ci_timings_start() {
    [[ -n "${SPOTTY_CI_TIMINGS_REPORT:-}" ]] || return 0
    spotty_ci_timings_finish 0
    spotty_ci_timing_phase="$1"
    spotty_ci_timing_log="${2:-}"
    spotty_ci_timing_events="${3:-}"
    spotty_ci_timing_owner_subshell="${ZSH_SUBSHELL:-${BASH_SUBSHELL:-0}}"
    if ! spotty_ci_timing_started="$(python3 "$project_root/Scripts/ci_timings.py" clock)"; then
        printf '%s\n' 'ci-timings: timing clock unavailable' >&2
        spotty_ci_timing_phase=""
    fi
}

spotty_ci_timings_finish() {
    [[ -n "${spotty_ci_timing_phase:-}" ]] || return 0
    # Inherited error traps in command substitutions must leave the parent's span
    # for its owning shell to finish with the command substitution's actual status.
    [[ "${ZSH_SUBSHELL:-${BASH_SUBSHELL:-0}}" == "${spotty_ci_timing_owner_subshell:-0}" ]] || return 0
    local phase_status="${1:-0}"
    local record_arguments=(
        --report "$SPOTTY_CI_TIMINGS_REPORT" --phase "$spotty_ci_timing_phase"
        --start "$spotty_ci_timing_started" --status "$phase_status"
    )
    if [[ -n "${spotty_ci_timing_log:-}" ]]; then
        record_arguments+=(--swift-test-log "$spotty_ci_timing_log")
    fi
    if [[ -n "${spotty_ci_timing_events:-}" ]]; then
        record_arguments+=(--native-events "$spotty_ci_timing_events")
    fi
    python3 "$project_root/Scripts/ci_timings.py" record "${record_arguments[@]}" || true
    spotty_ci_timing_phase=""
    return 0
}
