#!/bin/bash

set -euo pipefail

#######################################
# Main function.
# Arguments:
#   Thread ID
#   Reply body.
#######################################
main() {
  if [[ "$#" -ne 2 ]]; then
    usage
    exit 2
  fi

  local thread_id="$1"
  local reply_body="$2"

  if [[ -z "${thread_id}" ]]; then
    fail_input 'Thread id must not be empty.'
  fi

  if [[ -z "${reply_body}" ]]; then
    fail_input 'Reply message must not be empty.'
  fi

  if ! command -v 'gh' >/dev/null 2>&1; then
    fail_api "Required command 'gh' is not available."
  fi

  reply_to_thread "${thread_id}" "${reply_body}"
  resolve_thread "${thread_id}"
}

#######################################
# Print usage information.
# Arguments:
#   None
# Outputs:
#   Writes usage information to stderr.
#######################################
usage() {
  cat >&2 <<'EOF'
Usage: resolve-comment.sh <thread-id> <message>

Post <message> to one review thread, then resolve that thread.
EOF
}

#######################################
# Log a message to stderr.
# Arguments:
#   Message to log.
# Outputs:
#   Writes message to stderr.
#######################################
log() {
  printf '%s\n' "$*" >&2
}

#######################################
# Fail with an API error exit code.
# Arguments:
#   Message to log.
#######################################
fail_api() {
  log "$*"
  exit 4
}

#######################################
# Fail with an input error exit code.
# Arguments:
#   Message to log.
#######################################
fail_input() {
  log "$*"
  exit 2
}

#######################################
# Reply to a GitHub PR thread.
# Arguments:
#   GitHub thread ID.
#   Body of the reply comment.
#######################################
reply_to_thread() {
  local thread_id="$1"
  local body="$2"
  local query

  # shellcheck disable=SC2016
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
    --field threadId="$thread_id" \
    --raw-field body="$body" \
    --raw-field query="$query" \
    --silent; then
    fail_api "Failed to reply to review thread '$thread_id'."
  fi
}

#######################################
# Resolve a GitHub PR thread.
# Arguments:
#   GitHub thread ID.
#######################################
resolve_thread() {
  local thread_id="$1"
  local query

  # shellcheck disable=SC2016
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
    --field threadId="$thread_id" \
    --raw-field query="$query" \
    --silent; then
    fail_api "Failed to resolve review thread '$thread_id'."
  fi
}

main "$@"
