#!/bin/bash

set -euo pipefail

readonly POLL_INTERVAL_SECONDS=15
readonly POLL_TIMEOUT_SECONDS=2700
readonly STABLE_SUCCESS_SECONDS=30

readonly EXIT_FAILED_CHECKS=1
readonly EXIT_TIMEOUT=3
readonly EXIT_API_FAILURE=4

log() {
  printf '%s\n' "$*" >&2
}

fail_api() {
  log "$*"
  exit "${EXIT_API_FAILURE}"
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail_api "Required command '${command_name}' is not available."
  fi
}

fetch_checks() {
  local required="$1"
  local checks
  local status

  set +e
  if [[ "${required}" == 'true' ]]; then
    checks=$(gh pr checks \
      --required \
      --json bucket,completedAt,description,event,link,name,startedAt,state,workflow \
      --jq '.' 2>&1)
  else
    checks=$(gh pr checks \
      --json bucket,completedAt,description,event,link,name,startedAt,state,workflow \
      --jq '.' 2>&1)
  fi
  status=$?
  set -e

  if jq -e 'type == "array"' <<< "${checks}" >/dev/null 2>&1; then
    printf '%s' "${checks}"
    return 0
  fi

  if (( status != 0 )); then
    if [[ "${required}" == 'true' && ( "${checks}" == *'no checks reported'* || "${checks}" == *'no required checks reported'* ) ]]; then
      printf '[]'
      return 0
    fi

    if [[ -n "${checks}" ]]; then
      log "${checks}"
    fi
    log 'Failed to fetch pull request checks from GitHub.'
    return "${EXIT_API_FAILURE}"
  fi

  log 'GitHub returned an invalid pull request checks response.'
  return "${EXIT_API_FAILURE}"
}

select_failed_checks() {
  local checks_json="$1"

  jq '
    [
      .[]
      | select(.bucket == "fail" or .bucket == "cancel")
      | {
          name,
          workflow,
          state,
          bucket,
          link,
          startedAt,
          completedAt
        }
    ]
  ' <<< "${checks_json}"
}

has_pending_checks() {
  local checks_json="$1"

  jq -e 'any(.[]; .bucket == "pending")' <<< "${checks_json}" >/dev/null
}

build_check_status_snapshot() {
  local checks_json="$1"

  jq '
    [
      .[]
      | {
          key: ([.workflow // "", .name // "", .event // ""] | @json),
          value: {
            name,
            workflow,
            event,
            state,
            bucket,
            link,
            startedAt,
            completedAt
          }
        }
    ]
    | from_entries
  ' <<< "${checks_json}"
}

log_check_status_changes() {
  local previous_snapshot="$1"
  local current_snapshot="$2"

  jq -r \
    --argjson previous "${previous_snapshot}" \
    '
      to_entries[]
      | .key as $key
      | .value as $check
      | ($previous[$key] // null) as $old
      | select($check.bucket != "skipping" and $check.state != "SKIPPED")
      | select($old == null or $old.bucket != $check.bucket or $old.state != $check.state)
      | (($check.workflow // "Unknown workflow") + " / " + ($check.name // "Unknown check")) as $label
      | if $old == null then
          "Check status: \($label) is \($check.bucket) (\($check.state))."
        elif $check.bucket == "pass" then
          "Check passed: \($label)."
        elif $check.bucket == "fail" then
          "Check failed: \($label) (\($check.state)). \($check.link // "")"
        elif $check.bucket == "cancel" then
          "Check cancelled: \($label) (\($check.state)). \($check.link // "")"
        elif $check.bucket == "pending" then
          "Check pending: \($label) (\($old.state) -> \($check.state))."
        else
          "Check status changed: \($label) (\($old.bucket)/\($old.state) -> \($check.bucket)/\($check.state))."
        end
    ' <<< "${current_snapshot}" >&2
}

main() {
  local started_at
  local checks_json
  local all_checks_json
  local current_checks_snapshot
  local failed_checks_json
  local failed_count
  local required_check_count
  local previous_checks_snapshot='{}'
  local stable_success_started_at=''
  local has_logged_waiting='false'
  local has_logged_stable_success='false'

  require_command 'gh'
  require_command 'jq'

  started_at=$(date +%s)

  while true; do
    if checks_json=$(fetch_checks 'true'); then
      :
    else
      exit "$?"
    fi

    if required_check_count=$(jq 'length' <<< "${checks_json}"); then
      :
    else
      fail_api 'Failed to count required pull request checks.'
    fi

    if (( required_check_count == 0 )); then
      log 'No required pull request checks are configured; continuing.'
      exit 0
    fi

    if all_checks_json=$(fetch_checks 'false'); then
      :
    else
      exit "$?"
    fi

    if current_checks_snapshot=$(build_check_status_snapshot "${all_checks_json}"); then
      :
    else
      fail_api 'Failed to build pull request check status snapshot.'
    fi

    if log_check_status_changes "${previous_checks_snapshot}" "${current_checks_snapshot}"; then
      previous_checks_snapshot="${current_checks_snapshot}"
    else
      fail_api 'Failed to log pull request check status changes.'
    fi

    if failed_checks_json=$(select_failed_checks "${checks_json}"); then
      :
    else
      fail_api 'Failed to parse pull request check results.'
    fi

    if failed_count=$(jq 'length' <<< "${failed_checks_json}"); then
      :
    else
      fail_api 'Failed to count failed pull request checks.'
    fi

    if (( failed_count > 0 )); then
      jq '.' <<< "${failed_checks_json}"
      exit "${EXIT_FAILED_CHECKS}"
    fi

    if ! has_pending_checks "${checks_json}"; then
      if [[ -z "${stable_success_started_at}" ]]; then
        stable_success_started_at=$(date +%s)
      fi

      if (( $(date +%s) - stable_success_started_at >= STABLE_SUCCESS_SECONDS )); then
        exit 0
      fi

      if [[ "${has_logged_stable_success}" != 'true' ]]; then
        log "Required pull request checks are passing; waiting $STABLE_SUCCESS_SECONDS seconds to ensure no late checks appear."
        has_logged_stable_success='true'
      fi

      if (( $(date +%s) - started_at >= POLL_TIMEOUT_SECONDS )); then
        log 'Timed out while waiting for required pull request checks.'
        exit "${EXIT_TIMEOUT}"
      fi

      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    else
      stable_success_started_at=''
      has_logged_stable_success='false'
    fi

    if (( $(date +%s) - started_at >= POLL_TIMEOUT_SECONDS )); then
      log 'Timed out while waiting for required pull request checks.'
      exit "${EXIT_TIMEOUT}"
    fi

    if [[ "${has_logged_waiting}" != 'true' ]]; then
      log "Required pull request checks are still running; waiting for those to finish, or for $POLL_TIMEOUT_SECONDS seconds to pass — whichever happens sooner."
      has_logged_waiting='true'
    fi

    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

main "$@"
