---
name: push-and-watch
description: Push your changes and monitor the PR for feedback from `@copilot`.
---

# Push and Watch

Use this skill when the user asks to push finished work and watch the PR for checks or `@copilot` feedback.

## Available scripts

These paths are relative from the skill directory root, as per the Agent Skills Specification.

- `scripts/resolve-comment.sh` — Reply to and resolve a single comment thread.
- `scripts/wait-for-copilot.sh` — Wait for Copilot to finish reviewing the PR.
- `scripts/wait-for-pr-checks.sh` — Wait for required PR checks to pass.

## Workflow

1. Check the git status.
   - If the branch is `main`, stop and suggest creating a task branch.
   - If there is nothing to commit, skip to ‘3. Wait for required PR checks’ and continue from there.
   - Identify a JIRA issue from the branch name or task context when possible.

2. Commit staged changes.

3. Wait for required PR checks.
   - Push the current branch.
   - If no PR exists, create a draft PR.
   - Run `scripts/wait-for-pr-checks.sh`. While waiting for it to finish, don't report if there is no status change.
     - Exit `0`: continue to ‘4. Wait for Copilot’.
     - Exit `1`: stdout is a JSON array of failed/cancelled required checks. Fix them, then restart from ‘2. Commit your changes’.
     - Exit `3`: timeout. Stop and report the timeout.
     - Exit `4`: GitHub/API/auth failure.
       - Investigate the failure,
       - if a fix is possible, implement a fix for the failure, then restart from ‘2. Commit your changes’,
       - otherwise, stop and report the failure.

4. Wait for Copilot.
   - If the PR is still a draft PR, make it a ready PR.
   - Run `scripts/wait-for-copilot.sh`,
     - Exit `0`: Copilot approved the code; report completion.
     - Exit `2`: request a fresh review with `gh pr edit --add-reviewer '@copilot'`
       - if stdout was empty, rerun the script,
       - otherwise, continue to ‘5. Address Copilot feedback’ and remember that a fresh review was requested
     - Exit `3` or `4`: stop and report timeout or GitHub/API/auth failure.
     - Exit `1`: stdout is a JSON array of unresolved Copilot review threads
  
5. Address Copilot feedback.
   - Read the full git history for the current branch relative to the base branch to ground yourself. 
   - Objectively evaluate each feedback thread. Consider whether it's valid, worthwhile, actionable, and in-scope.
     - Be sceptical of feedback that is fully contrary to the intent of commits.
     - Ignore feedback about style or formatting, especially if the file in question is not dictated to follow any style spec.
   - Prepare a multi-phase plan to implement the feedback threads that passed evaluation.
   - For each feedback thread:
     - Commit the change as a separate commit but do not push yet.
     - Write a custom reply, run `scripts/resolve-comment.sh "<thread id>" "<custom reply>"`.
   - If the last exit code from `scripts/wait-for-copilot.sh` was `2`, and a fresh review was requested, return to ‘4. Wait for Copilot’,
   - otherwise, restart from ‘3. Wait for required PR checks’.
