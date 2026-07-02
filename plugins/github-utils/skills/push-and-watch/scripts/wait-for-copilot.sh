#!/bin/bash

set -euo pipefail

# GitHub requests Copilot as "copilot", while review comments are authored by "copilot-pull-request-reviewer".
readonly COPILOT_REVIEWER_LOGIN='copilot-pull-request-reviewer'
readonly COPILOT_REQUEST_LOGIN='copilot'

readonly POLL_INTERVAL_SECONDS=15
readonly POLL_TIMEOUT_SECONDS=600

readonly EXIT_HAS_FEEDBACK=1
readonly EXIT_NEEDS_REVIEW=2
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

fetch_copilot_timeline() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local query
  local response

  query='
    query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          timelineItems(
            first: 100,
            after: $endCursor,
            itemTypes: [REVIEW_REQUESTED_EVENT, PULL_REQUEST_REVIEW]
          ) {
            nodes {
              __typename

              ... on ReviewRequestedEvent {
                createdAt
                requestedReviewer {
                  __typename

                  ... on Bot {
                    login
                  }
                }
              }

              ... on PullRequestReview {
                id
                state
                createdAt
                submittedAt
                bodyText
                url
                author {
                  login
                }
                commit {
                  oid
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
    -F owner="${owner}" \
    -F repo="${repo}" \
    -F number="${number}" \
    -f query="${query}"); then
    log 'Failed to fetch Copilot review timeline from GitHub.'
    return "${EXIT_API_FAILURE}"
  fi

  printf '%s' "${response}"
}

build_copilot_state() {
  local timeline_json="$1"
  local head_ref_oid="$2"
  local state

  if ! state=$(jq \
    --arg reviewer "${COPILOT_REVIEWER_LOGIN}" \
    --arg requestLogin "${COPILOT_REQUEST_LOGIN}" \
    --arg headRefOid "${head_ref_oid}" \
    '
      [
        .[].data.repository.pullRequest.timelineItems.nodes[]
      ] as $items
      | [
          $items[]
          | select(.__typename == "ReviewRequestedEvent")
          | select(.requestedReviewer.__typename == "Bot")
          | select(.requestedReviewer.login == $requestLogin or .requestedReviewer.login == $reviewer)
        ] as $requests
      | [
          $items[]
          | select(.__typename == "PullRequestReview")
          | select(.author.login == $reviewer)
        ] as $reviews
      | [
          $reviews[]
          | select(.submittedAt != null)
        ] as $submittedReviews
      | ($requests | max_by(.createdAt // "")) as $latestRequest
      | ($submittedReviews | max_by(.submittedAt // "")) as $latestReview
      | {
          hasStarted: (($requests | length) > 0 or ($reviews | length) > 0),
          isRunning: (
            (any($reviews[]; .submittedAt == null))
            or ($latestRequest != null and $latestReview == null)
            or (
              $latestRequest != null
              and $latestReview != null
              and ($latestRequest.createdAt > $latestReview.submittedAt)
            )
          ),
          latestRequest: $latestRequest,
          latestReview: $latestReview,
          isStale: (
            $latestReview != null
            and (($latestReview.commit.oid // "") != $headRefOid)
          ),
          hasGeneratedNoNewCommentsMarker: (
            $latestReview != null
            and (($latestReview.bodyText // "") | test("generated no new comments"; "i"))
          )
        }
    ' <<< "${timeline_json}"); then
    log 'Failed to parse Copilot review timeline.'
    return "${EXIT_API_FAILURE}"
  fi

  printf '%s' "${state}"
}

fetch_review_threads() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local query
  local response

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
    -F owner="${owner}" \
    -F repo="${repo}" \
    -F number="${number}" \
    -f query="${query}"); then
    log 'Failed to fetch pull request review threads from GitHub.'
    return "${EXIT_API_FAILURE}"
  fi

  printf '%s' "${response}"
}

fetch_thread_comments() {
  local thread_id="$1"
  local query
  local response

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
    -F threadId="${thread_id}" \
    -f query="${query}"); then
    log "Failed to fetch comments for review thread '${thread_id}'."
    return "${EXIT_API_FAILURE}"
  fi

  if ! jq '[.[].data.node.comments.nodes[]]' <<< "${response}"; then
    log "Failed to parse comments for review thread '${thread_id}'."
    return "${EXIT_API_FAILURE}"
  fi
}

build_unresolved_copilot_feedback() {
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

  while IFS= read -r thread_json; do
    if [[ -z "${thread_json}" ]]; then
      continue
    fi

    local thread_id
    local comments_json
    local comments_have_next_page
    local has_copilot_comment
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

    if ! has_copilot_comment=$(jq \
      --arg reviewer "${COPILOT_REVIEWER_LOGIN}" \
      'any(.[]; .author.login == $reviewer)' <<< "${comments_json}"); then
      log "Failed to inspect comments for review thread '${thread_id}'."
      return "${EXIT_API_FAILURE}"
    fi

    if [[ "${has_copilot_comment}" != 'true' ]]; then
      continue
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
                diffHunk,
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

wait_for_copilot_state() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local head_ref_oid="$4"
  local started_at
  local has_logged_waiting='false'
  local timeline_json
  local state_json
  local has_started
  local is_running

  started_at=$(date +%s)

  while true; do
    if timeline_json=$(fetch_copilot_timeline "${owner}" "${repo}" "${number}"); then
      :
    else
      return "$?"
    fi

    if state_json=$(build_copilot_state "${timeline_json}" "${head_ref_oid}"); then
      :
    else
      return "$?"
    fi

    if has_started=$(jq -r '.hasStarted' <<< "${state_json}"); then
      :
    else
      log 'Failed to parse Copilot review state.'
      return "${EXIT_API_FAILURE}"
    fi

    if is_running=$(jq -r '.isRunning' <<< "${state_json}"); then
      :
    else
      log 'Failed to parse Copilot review state.'
      return "${EXIT_API_FAILURE}"
    fi

    if [[ "${has_started}" != 'true' ]]; then
      log 'No Copilot review has been requested or submitted for this pull request.'
      return "${EXIT_NEEDS_REVIEW}"
    fi

    if [[ "${is_running}" != 'true' ]]; then
      printf '%s' "${state_json}"
      return 0
    fi

    if (( $(date +%s) - started_at >= POLL_TIMEOUT_SECONDS )); then
      log 'Timed out while waiting for Copilot review to finish.'
      return "${EXIT_TIMEOUT}"
    fi

    if [[ "${has_logged_waiting}" != 'true' ]]; then
      log "Copilot review appears to be running; waiting for it to finish, or for $POLL_TIMEOUT_SECONDS seconds to pass — whichever comes first."
      has_logged_waiting='true'
    fi

    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

main() {
  local pr_json
  local owner
  local repo
  local number
  local head_ref_oid
  local state_json
  local feedback_json
  local feedback_count
  local is_stale
  local has_generated_no_new_comments_marker

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

  if state_json=$(wait_for_copilot_state "${owner}" "${repo}" "${number}" "${head_ref_oid}"); then
    :
  else
    exit "$?"
  fi

  if feedback_json=$(build_unresolved_copilot_feedback "${owner}" "${repo}" "${number}"); then
    :
  else
    exit "$?"
  fi

  if feedback_count=$(jq 'length' <<< "${feedback_json}"); then
    :
  else
    fail_api 'Failed to count unresolved Copilot feedback.'
  fi

  if is_stale=$(jq -r '.isStale' <<< "${state_json}"); then
    :
  else
    fail_api 'Failed to parse Copilot review staleness.'
  fi

  if has_generated_no_new_comments_marker=$(jq -r '.hasGeneratedNoNewCommentsMarker' <<< "${state_json}"); then
    :
  else
    fail_api 'Failed to parse latest Copilot review summary.'
  fi

  if (( feedback_count > 0 )); then
    jq '.' <<< "${feedback_json}"

    if [[ "${is_stale}" == 'true' ]]; then
      log 'Latest Copilot review is stale; request a new Copilot review.'
      exit "${EXIT_NEEDS_REVIEW}"
    fi

    exit "${EXIT_HAS_FEEDBACK}"
  fi

  if [[ "${is_stale}" == 'true' ]]; then
    log 'Latest Copilot review is stale; request a new Copilot review.'
    exit "${EXIT_NEEDS_REVIEW}"
  fi

  if [[ "${has_generated_no_new_comments_marker}" == 'true' ]]; then
    exit 0
  fi

  log 'No unresolved Copilot feedback was found, but the latest Copilot review did not report "generated no new comments".'
  exit "${EXIT_NEEDS_REVIEW}"
}

main "$@"
