#!/bin/bash

set -euo pipefail

readonly EXIT_NO_FEEDBACK=0
readonly EXIT_HAS_FEEDBACK=1
readonly EXIT_API_FAILURE=3

#######################################
# Main function.
# Arguments:
#   None
#######################################
main() {
  local pr_json
  local owner
  local repo
  local number
  local head_ref_oid
  local feedback_json
  local feedback_count

  require_command 'gh'
  require_command 'jq'

  if pr_json=$(get_pr_metadata); then
    :
  else
    exit "$?"
  fi

  if owner=$(jq -r '.owner' <<< "${pr_json}"); then
    :
  else
    fail_api 'Failed to parse pull request owner.'
  fi

  if repo=$(jq -r '.repo' <<< "${pr_json}"); then
    :
  else
    fail_api 'Failed to parse pull request repository.'
  fi

  if number=$(jq -r '.number' <<< "${pr_json}"); then
    :
  else
    fail_api 'Failed to parse pull request number.'
  fi

  if head_ref_oid=$(jq -r '.headRefOid' <<< "${pr_json}"); then
    :
  else
    fail_api 'Failed to parse pull request head commit.'
  fi

  if [[ -z "${owner}" || -z "${repo}" || -z "${number}" || -z "${head_ref_oid}" ]]; then
    fail_api 'Pull request metadata is incomplete.'
  fi

  if feedback_json=$(build_unresolved_feedback "${owner}" "${repo}" "${number}"); then
    :
  else
    exit "$?"
  fi

  if feedback_count=$(jq 'length' <<< "${feedback_json}"); then
    :
  else
    fail_api 'Failed to count unresolved feedback.'
  fi

  if (( feedback_count > 0 )); then
    jq '.' <<< "${feedback_json}"

    exit "${EXIT_HAS_FEEDBACK}"
  fi

  log 'No unresolved feedback was found.'
  exit "${EXIT_NO_FEEDBACK}"
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

get_pr_metadata() {
  local metadata

  if ! metadata=$(gh pr view \
    --json number,headRefOid,headRepository,headRepositoryOwner,state,url \
    --jq '{
      number,
      headRefOid,
      owner: .headRepositoryOwner.login,
      repo: .headRepository.name,
      state,
      url
    }'); then
    log 'Failed to inspect the pull request for the current branch.'
    return "${EXIT_API_FAILURE}"
  fi

  printf '%s' "${metadata}"
}

fetch_review_threads() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local query
  local response

  # shellcheck disable=SC2016
  query='
    query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              startLine
              originalLine
              originalStartLine
              diffSide
              startDiffSide
              subjectType
              viewerCanResolve
              comments(first: 100) {
                nodes {
                  id
                  author {
                    login
                  }
                  bodyText
                  createdAt
                  updatedAt
                  url
                  path
                  line
                  originalLine
                  diffHunk
                  pullRequestReview {
                    id
                  }
                }
                pageInfo {
                  hasNextPage
                  endCursor
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
  '

  if ! response=$(gh api graphql \
    --paginate \
    --slurp \
    --field owner="${owner}" \
    --field repo="${repo}" \
    --field number="${number}" \
    --raw-field query="${query}"); then
    log 'Failed to fetch pull request review threads from GitHub.'
    return "${EXIT_API_FAILURE}"
  fi

  printf '%s' "${response}"
}

fetch_thread_comments() {
  local thread_id="$1"
  local query
  local response

  # shellcheck disable=SC2016
  query='
    query($threadId: ID!, $endCursor: String) {
      node(id: $threadId) {
        ... on PullRequestReviewThread {
          comments(first: 100, after: $endCursor) {
            nodes {
              id
              author {
                login
              }
              bodyText
              createdAt
              updatedAt
              url
              path
              line
              originalLine
              diffHunk
              pullRequestReview {
                id
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
  '

  if ! response=$(gh api graphql \
    --paginate \
    --slurp \
    --field threadId="${thread_id}" \
    --raw-field query="${query}"); then
    log "Failed to fetch comments for review thread '${thread_id}'."
    return "${EXIT_API_FAILURE}"
  fi

  if ! jq '[.[].data.node.comments.nodes[]]' <<< "${response}"; then
    log "Failed to parse comments for review thread '${thread_id}'."
    return "${EXIT_API_FAILURE}"
  fi
}

build_unresolved_feedback() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local threads_json
  local results='[]'
  local unresolved_threads_json

  if threads_json=$(fetch_review_threads "${owner}" "${repo}" "${number}"); then
    :
  else
    return "$?"
  fi

  if ! unresolved_threads_json=$(jq -c '
    [
      .[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
    ]
  ' <<< "${threads_json}"); then
    log 'Failed to parse pull request review threads.'
    return "${EXIT_API_FAILURE}"
  fi

  local thread_json

  while IFS= read -r thread_json; do
    if [[ -z "${thread_json}" ]]; then
      continue
    fi

    local thread_id
    local comments_json
    local comments_have_next_page
    local thread_result

    if ! thread_id=$(jq -r '.id' <<< "${thread_json}"); then
      log 'Failed to parse a pull request review thread identifier.'
      return "${EXIT_API_FAILURE}"
    fi

    if ! comments_have_next_page=$(jq -r '.comments.pageInfo.hasNextPage // false' <<< "${thread_json}"); then
      log "Failed to inspect comment pagination for review thread '${thread_id}'."
      return "${EXIT_API_FAILURE}"
    fi

    if [[ "${comments_have_next_page}" == 'true' ]]; then
      if comments_json=$(fetch_thread_comments "${thread_id}"); then
        :
      else
        return "$?"
      fi
    elif ! comments_json=$(jq '[.comments.nodes[]]' <<< "${thread_json}"); then
      log "Failed to parse comments for review thread '${thread_id}'."
      return "${EXIT_API_FAILURE}"
    fi

    if ! thread_result=$(jq \
      --argjson thread "${thread_json}" \
      --argjson comments "${comments_json}" \
      '
        {
          id: $thread.id,
          isResolved: $thread.isResolved,
          isOutdated: $thread.isOutdated,
          path: $thread.path,
          line: $thread.line,
          startLine: $thread.startLine,
          originalLine: $thread.originalLine,
          originalStartLine: $thread.originalStartLine,
          diffSide: $thread.diffSide,
          startDiffSide: $thread.startDiffSide,
          subjectType: $thread.subjectType,
          viewerCanResolve: $thread.viewerCanResolve,
          url: ($comments[0].url // null),
          comments: [
            $comments[]
            | {
                id,
                author: (.author.login // null),
                bodyText,
                createdAt,
                updatedAt,
                url,
                path,
                line,
                originalLine,
                reviewId: (.pullRequestReview.id // null)
              }
          ]
        }
      ' <<< '{}'); then
      log "Failed to build JSON output for review thread '${thread_id}'."
      return "${EXIT_API_FAILURE}"
    fi

    if ! results=$(jq \
      --argjson results "${results}" \
      --argjson thread "${thread_result}" \
      '$results + [$thread]' <<< '{}'); then
      log 'Failed to append a review thread to the JSON output.'
      return "${EXIT_API_FAILURE}"
    fi
  done < <(jq -c '.[]' <<< "${unresolved_threads_json}")

  printf '%s' "${results}"
}

main "$@"
