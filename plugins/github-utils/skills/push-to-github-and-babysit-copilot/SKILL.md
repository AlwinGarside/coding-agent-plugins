---
name: push-to-github-and-babysit-copilot
description: Push changes to a GitHub repo, ensure a PR exists and monitor it for feedback from `@copilot`.
---

# Push to GitHub and babysit `@copilot`

## Available scripts

These paths are relative from the skill directory root, as per the Agent Skills Specification.

- `scripts/resolve-comment.sh` — Reply to and resolve a single comment thread.
- `scripts/wait-for-copilot.sh` — Wait for Copilot to finish reviewing the PR.
- `scripts/wait-for-pr-checks.sh` — Wait for required PR checks to pass.

## Workflow

1. Check the git status

   - If this is not a GitHub repo, stop and inform the user.
   - If the branch is `main`, stop and suggest creating a task branch.
   - If there is nothing to commit, skip to ‘3. Push and wait for required PR checks’ and continue from there.
   - Identify a JIRA issue from the branch name or task context when possible.

2. Commit staged changes

3. Push and wait for required PR checks

   - Push the current branch.
   - If no PR exists, create a draft PR.
   - Run `scripts/wait-for-pr-checks.sh`. While waiting for it to finish, don't report if there is no status change.
     - Exit `0`: continue to ‘4. Wait for Copilot’.
     - Exit `1`: stdout is a JSON array of failed/cancelled required checks; fix them, then restart from ‘2. Commit staged changes’.
     - Exit `3`: timeout. Stop and report the timeout.
     - Exit `4`: GitHub/API/auth failure.
       - Investigate the failure,
       - if a fix is possible, implement a fix for the failure, then restart from ‘2. Commit staged changes’,
       - otherwise, stop and report the failure.

4. Wait for Copilot
   
   - If the PR is still a draft PR, make it a ready PR.
   - Run `scripts/wait-for-copilot.sh`,
     - Exit `0`: Copilot review finished without unresolved feedback. `stdout` is the raw review body, if any.  
       Inspect the review body:
       - if it contains actionable concerns that the script did not recognize, treat each concern as feedback and continue to ‘5. Address Copilot feedback’;
       - otherwise, skip to ‘6. Done’.
     - Exit `1`: `stdout` is a JSON array containing unresolved Copilot review threads and, when present, one `suppressed_review_body` record with the complete review body; continue to ‘5. Address Copilot feedback’.
     - Exit `2`: the last submitted review is stale or no Copilot review has started. `stdout` uses the same feedback-array format as exit `1`, when feedback exists. Request a fresh `@copilot` review with `gh pr edit --add-reviewer '@copilot'`
       - if `stdout` was empty, rerun the script,
       - otherwise, continue to ‘5. Address Copilot feedback’ and remember that a fresh review was requested
     - Exit `3` or `4`: stop and report timeout or GitHub/API/auth failure.
  
5. Address Copilot feedback
   
   For each feedback item:

   - A review thread has an `id` and a `comments` array.
   - A suppressed-review record has `kind: "suppressed_review_body"`.  
     Extract and evaluate each suppressed comment in its `body` separately. Suppressed comments have no GitHub thread to reply to or resolve.
   
   a. Start a fresh worker subagent with no inherited conversation turns or previous-thread context.
   b. Give the fresh subagent only:
      - `AGENTS.md` instructions;
      - one review thread or one suppressed comment;
      - the issue lifecycle instructions below.
   c. The subagent must:
      - Objectively evaluate the feedback. Consider whether it's valid, worthwhile, actionable, and in-scope.
        - Be sceptical of feedback that is fully contrary to the intent of commits.
        - Ignore feedback about style or formatting, especially if the file in question is not dictated to follow any style spec.
      - If the feedback passes evaluation,
        - implement a fix;
        - commit the changes as a separate commit, but do not push yet;
        - for a review thread, write a custom reply and resolve it using `scripts/resolve-comment.sh "‹thread id›" "‹custom reply›"`;
        - for a suppressed comment, do not call `resolve-comment.sh` because no GitHub thread exists.
   d. If the last exit code from `scripts/wait-for-copilot.sh` was `2`, and a fresh review was requested, return to ‘4. Wait for Copilot’,  
      otherwise, restart from ‘3. Push and wait for required PR checks.’.

6. Done
   
   Present the user with an overview of the feedback, if any, and how each was addressed.
