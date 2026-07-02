#!/bin/bash

set -euo pipefail

readonly EXIT_INVALID_INPUT=2
readonly EXIT_API_FAILURE=4

log() {
  printf '%s\n' "$*" >&2
}

fail_api() {
  log "$*"
  exit "${EXIT_API_FAILURE}"
}

fail_input() {
  log "$*"
  exit "${EXIT_INVALID_INPUT}"
}

usage() {
  cat >&2 <<'EOF'
Usage: resolve-comment.sh <thread-id> <message>

Post <message> to one review thread, then resolve that thread.
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail_api "Required command '${command_name}' is not available."
  fi
}

reply_to_thread() {
  local thread_id="$1"
  local body="$2"
  local query

  query='
    mutation($threadId: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $threadId,
        body: $body
      }) {
        comment {
          id
        }
      }
    }
  '

  if ! gh api graphql \
    -F threadId="${thread_id}" \
    -f body="${body}" \
    -f query="${query}" \
    --silent; then
    fail_api "Failed to reply to review thread '${thread_id}'."
  fi
}

resolve_thread() {
  local thread_id="$1"
  local query

  query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {
        threadId: $threadId
      }) {
        thread {
          id
          isResolved
        }
      }
    }
  '

  if ! gh api graphql \
    -F threadId="${thread_id}" \
    -f query="${query}" \
    --silent; then
    fail_api "Failed to resolve review thread '${thread_id}'."
  fi
}

main() {
  if [[ "$#" -ne 2 ]]; then
    usage
    exit "${EXIT_INVALID_INPUT}"
  fi

  local thread_id="$1"
  local reply_body="$2"

  if [[ -z "${thread_id}" ]]; then
    fail_input 'Thread id must not be empty.'
  fi

  if [[ -z "${reply_body}" ]]; then
    fail_input 'Reply message must not be empty.'
  fi

  require_command 'gh'

  reply_to_thread "${thread_id}" "${reply_body}"
  resolve_thread "${thread_id}"
}

main "$@"
