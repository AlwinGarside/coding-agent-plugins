# Detecting whether Copilot approved a pull request

Research date: 2026-08-06

## Conclusion

GitHub's public APIs do not currently expose Copilot's new assessment as a structured field. There is therefore no reliable, body-independent way to decide that Copilot “approves” a pull request.

The implemented workflow deliberately uses a narrower operational rule instead of claiming approval. It succeeds after a Copilot review finishes for the current commit when no published Copilot thread remains unresolved and the recognized review-body format contains no suppressed comments. The raw review body is emitted on success so the calling agent can inspect concerns or future formats that the shell parser does not recognize.

Structured checks for completion, staleness, and unresolved threads remain useful, but they cannot prove approval and should not be described as doing so. Findings visible only in session activity or execution logs are unpublished and are not considered.

## What GitHub documents

GitHub documents that Copilot code review always submits a **Comment** review, not **Approve** or **Request changes**. Consequently, its reviews do not count toward required approvals and do not block a merge. This directly rules out using `PullRequestReview.state` to distinguish Copilot's present positive and negative assessments: they are all `COMMENTED`. See [Using GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review?tool=cli).

The REST review endpoint exposes a review's author, body, `state`, `submitted_at`, and `commit_id`; GitHub describes a pull request review as a group of review comments with a state and optional body. It exposes no separate Copilot assessment or verdict field. See [REST API endpoints for pull request reviews](https://docs.github.com/en/rest/pulls/reviews) and the [GraphQL pull-request schema](https://docs.github.com/en/graphql/reference/pulls).

A live GraphQL schema introspection on the research date found these relevant `PullRequestReview` fields: `author`, `body`, `bodyHTML`, `bodyText`, `comments`, `commit`, `state`, `submittedAt`, and `url`. No assessment, verdict, or Copilot-specific result field was present. `PullRequest.reviewDecision` is not suitable because it summarizes the pull request's overall review status; it does not identify which reviewer produced the decision.

GitHub defines `APPROVED` as an approving review and `COMMENTED` as an informational review. Therefore, a future Copilot-authored `APPROVED` state would be a suitable structured signal, but `COMMENTED` must not be interpreted as approval. The current documentation says Copilot does not emit that approving state.

## Evidence from `Yogarine/Mailboy#126`

The pull request demonstrates why the old text marker and the apparent API alternatives are insufficient.

### Actor identity

In GraphQL, both the review request target and review author are the same bot object:

- `__typename`: `Bot`
- `id`: `BOT_kgDOCnlnWA`
- `databaseId`: `175728472`
- `login`: `copilot-pull-request-reviewer`
- `resourcePath`: `/apps/copilot-pull-request-reviewer`

The REST representation uses `copilot-pull-request-reviewer[bot]` in review payloads and normalizes the actor's displayed login to `Copilot` in some other payloads. GitHub's Copilot documentation also tells REST clients to request `copilot-pull-request-reviewer[bot]`. Matching the GraphQL global node ID plus `__typename == Bot` is consequently stronger than matching display text or relying on REST login normalization. GitHub recommends treating global node IDs as opaque, unique references; see [Using global node IDs](https://docs.github.com/en/graphql/guides/using-global-node-ids).

The script currently allows both `copilot` and `copilot-pull-request-reviewer` for review-request events. In this pull request, the GraphQL event's actual requested-reviewer login is `copilot-pull-request-reviewer`, so the latter branch is the one that matches.

### Review state cannot distinguish the verdict

Copilot submitted assessments such as:

- [“Not ready to approve”](https://github.com/Yogarine/Mailboy/pull/126#pullrequestreview-4847899415)
- [“Human review recommended”](https://github.com/Yogarine/Mailboy/pull/126#pullrequestreview-4847599390)

Both reviews have `state == COMMENTED`. The earlier review that generated four published inline comments is also [a `COMMENTED` review](https://github.com/Yogarine/Mailboy/pull/126#pullrequestreview-4841970234). The machine-readable state therefore records the GitHub review type, not the new assessment heading.

### Zero comments or threads does not mean approval

Review `4847899415` says “Not ready to approve” and reports two **suppressed comments** in its body, but the REST review-comments collection contains no comments associated with that review. All four Copilot review threads in the pull request belong to the first review, `4841970234`; the later suppressed findings do not have review-thread objects.

This is an important distinction:

- `PullRequestReview.comments` and `PullRequest.reviewThreads` represent published inline feedback.
- The new review assessment can include findings only inside the review body as suppressed comments.

Thus, “no unresolved Copilot threads,” “zero comments on the latest review,” and “all prior threads resolved” can all be true while Copilot's latest assessment is not approval. See the live [review payload](https://api.github.com/repos/Yogarine/Mailboy/pulls/126/reviews/4847899415) and that review's empty [review-comments collection](https://api.github.com/repos/Yogarine/Mailboy/pulls/126/reviews/4847899415/comments).

### A successful check means the reviewer ran, not that it approved

Commit `12b5dc65fb01bf6a1db183c17dd6d9f5b502c22f` has check run `91794492833`:

- name: `copilot-pull-request-reviewer`
- app: `github-actions`
- status: `completed`
- conclusion: `success`
- output annotations: `0`

That same commit received the “Not ready to approve” review above. The pull request's initial reviewed commit also had a successful reviewer check while Copilot published four inline findings. The check conclusion therefore means that the review workflow completed successfully, not that the code passed Copilot's assessment. GitHub describes a check run as an individual process with execution status and conclusion; see [Using the REST API to interact with checks](https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-checks) and the live [check-run payload](https://api.github.com/repos/Yogarine/Mailboy/check-runs/91794492833).

### Freshness and pending-review fields remain useful

The latest submitted Copilot review on this pull request is attached to commit `12b5dc65fb01bf6a1db183c17dd6d9f5b502c22f`, while the eventual head commit is `ef596c5e0796ecf59ea9cf84cd4164f06fd2c078`. A review request was created after the latest submitted review. These structured values correctly establish that the latest review is stale and a newer request is outstanding. They say nothing about whether the submitted review's assessment was positive.

### Agent Task sessions do not expose a verdict

The supplied session URL redirects authenticated users to Agent Task `05fdf8f8-6504-4ae5-adae-20b6b22367ed`. GitHub's public-preview Agent Tasks API can retrieve that task with `gh api agents/repos/Yogarine/Mailboy/tasks/05fdf8f8-6504-4ae5-adae-20b6b22367ed`. The response includes session identity, execution state, timestamps, refs, and model, but no transcript, findings, assessment, verdict, or approval field. GitHub documents task and session metadata but no endpoint for retrieving a session by its session ID; see [REST API endpoints for agent tasks](https://docs.github.com/en/rest/agent-tasks/agent-tasks).

The authenticated session page and its GitHub Actions log contain internal records for findings that were not published in a pull request review. Those records are undocumented implementation details and are deliberately excluded from the script's feedback contract. Only published review threads and suppressed comments contained in a published review body are considered.

## Comparison of candidate signals

| Signal | Machine-readable? | What it establishes | Can prove Copilot approval now? |
| --- | --- | --- | --- |
| Copilot `PullRequestReview.state` | Yes | GitHub review type | No. GitHub documents that Copilot uses `COMMENTED`. |
| `PullRequest.reviewDecision` | Yes | Overall PR review status | No. It is not attributable to Copilot and may reflect human reviews or branch rules. |
| Review `commit.oid` / REST `commit_id` | Yes | Which commit Copilot reviewed | No; useful for staleness only. |
| Review request and submission timestamps | Yes | Whether Copilot is still expected to respond | No; useful for polling only. |
| Check run `status` and `conclusion` | Yes | Whether the reviewer workflow executed successfully | No; `success` coexists with “Not ready to approve.” |
| Latest review's inline-comment count | Yes | Published comments generated by that review | No; suppressed findings exist only in the review body. |
| Unresolved Copilot review threads | Yes | Published feedback still open | No; suppressed findings have no thread. |
| Assessment heading in `body` / `bodyText` | No; unstructured text | Copilot's current assessment | Yes in practice, but only through an undocumented format dependency. |
| Agent Task session metadata | Yes | Whether the Copilot task/session ran | No; the public API exposes no transcript, findings, or verdict. |

## Implemented feedback rule

The script evaluates published Copilot feedback as follows:

1. Use structured GraphQL fields to establish that Copilot submitted a review for the current head commit and that no newer request is pending.
2. Return every unresolved published Copilot review thread, including threads created by older reviews.
3. Recognize a positive `Suppressed comments (N)` count in the latest published review body's plain-text rendering and return the complete raw body as one feedback record.
4. If the review is fresh and neither feedback form is present, exit successfully and emit the raw review body for agent inspection.
5. If GitHub changes the body format, preserve workflow progress: the parser may report no suppressed comments, but the calling agent must inspect the emitted body before declaring the work complete.

This is a published-feedback rule, not a GitHub approval. Do not infer approval from the review state, assessment heading, “comments generated” count, emoji color, check conclusion, or Agent Task session state. Unpublished session-only findings are outside the rule.

## Suggested query shape

One paginated GraphQL query can retrieve the required structured state:

```graphql
query ($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefOid
      timelineItems(
        first: 100
        after: $cursor
        itemTypes: [REVIEW_REQUESTED_EVENT, PULL_REQUEST_REVIEW]
      ) {
        nodes {
          __typename
          ... on ReviewRequestedEvent {
            createdAt
            requestedReviewer {
              __typename
              ... on Bot { id login }
            }
          }
          ... on PullRequestReview {
            id
            state
            submittedAt
            url
            body
            bodyText
            author {
              __typename
              login
              ... on Bot { id }
            }
            commit { oid }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 100) {
            nodes {
              author {
                __typename
                login
                ... on Bot { id }
              }
              pullRequestReview { id }
              url
            }
          }
        }
      }
    }
  }
}
```

Use `BOT_kgDOCnlnWA` as the observed Copilot reviewer node ID, but keep the expected ID in one named constant and fail with a diagnostic if GitHub presents a different bot identity. Node IDs should be treated as opaque strings.

## Reproduction commands

The principal observations can be reproduced with first-party APIs:

```bash
gh api --paginate repos/Yogarine/Mailboy/pulls/126/reviews
gh api --paginate repos/Yogarine/Mailboy/pulls/126/comments
gh api repos/Yogarine/Mailboy/commits/12b5dc65fb01bf6a1db183c17dd6d9f5b502c22f/check-runs
gh api repos/Yogarine/Mailboy/check-runs/91794492833
```

GraphQL was used to correlate review requests, review author IDs, review commit OIDs, and thread resolution state. The API data was inspected on 2026-08-06; PR #126 itself was merged on 2026-08-04.
