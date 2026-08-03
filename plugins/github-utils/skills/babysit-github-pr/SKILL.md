---
name: babysit-github-pr
description: Monitor a GitHub PR for feedback until it has enough approvals and all outstanding feedback is resolved.
---

# Babysit a GitHub PR

## Available scripts

These paths are relative from the skill directory root, as per the Agent Skills Specification.

- `scripts/check-for-feedback.sh` — Wait for Copilot to finish reviewing the PR.
- `scripts/resolve-pr-comment.sh` — Reply to and resolve a single comment thread.
- `scripts/wait-for-pr-checks.sh` — Wait for required PR checks to pass.

## Workflow

1. Check the git status
   
   - If this is not a GitHub repo, stop and inform the user.
   - If the branch is `main`, stop and suggest creating a task branch.
   - If there are uncommitted changes, stop and suggest committing the changes first.
   - Identify a JIRA issue from the branch name or task context when possible.

2. Push and wait for required PR checks
   
   - Push the current branch.
   - If no PR exists, create a draft PR.
   - Run `scripts/wait-for-pr-checks.sh`. While waiting for it to finish, don't report if there is no status change.
     - Exit `0`: continue to ‘3. Check for feedback’.
     - Exit `1`: stdout is a JSON array of failed/cancelled required checks; fix them, then restart from ‘2. Commit your changes’.
     - Exit `3`: timeout. Stop and report the timeout.
     - Exit `4`: GitHub/API/auth failure.
       - Investigate the failure;
       - if a fix is possible, implement a fix for the failure, then restart from ‘2. Push and wait for required PR checks’,
       - otherwise, stop and report the failure.

3. Check for feedback
   
   - If the PR is still a draft PR, make it a ready PR.
   - Run `scripts/check-for-feedback.sh`,
     - Exit `0`: There is no feedback yet; skip to ‘5. Evaluate’.
     - Exit `1`: `stdout` is a JSON array of unresolved Copilot review thread; continue to ‘4. Address feedback’.
     - Exit `3`: Stop and report timeout or GitHub/API/auth failure.

4. Address feedback
   
   For each feedback thread:
   
   a. Start a fresh worker subagent with no inherited conversation turns or previous-thread context.
   b. Give the fresh subagent only:
      - `AGENTS.md` instructions;
      - the feedback thread;
      - the issue lifecycle instructions below.
   c. The worker subagent must:  
      - Objectively evaluate each feedback thread. Consider whether it's valid, worthwhile, actionable, and in-scope.
        - Be sceptical of feedback that is fully contrary to the intent of commits.
        - Ignore feedback about style or formatting, especially if the file in question is not dictated to follow any style spec.
      - If the feedback passes evaluation,
        - implement a fix;
        - commit the changes as a separate commit, but do not push yet;
        - write a custom reply to the thread using `scripts/resolve-comment.sh "<thread id>" "<custom reply>"`.
   d. When all subagents are done, restart from ‘2. Push and wait for required PR checks’.

5. Evaluate
   
   Check the PR state;
   
   - if the PR is “Ready to Merge”, you're done; continue to ‘6. Done’,
   - otherwise, wait a reasonable amount and restart from ‘3. Check for feedback’.
   
   > [!NOTE]
   > This skill has no timeout, the idea is to keep checking for feedback until all feedback is resolved _and_ the PR is “Ready to Merge”.

6. Done
   
   Present the user with an overview of the feedback, if any, and how each was addressed.
