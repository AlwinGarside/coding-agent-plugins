# GitHub Agent Plugins

This context defines the review-feedback terms used by the repository's GitHub automation skills.

## Language

**Fresh review**:
A submitted Copilot review whose reviewed commit is the pull request's current head commit.
_Avoid_: Current review

**Stale review**:
A submitted Copilot review whose reviewed commit is not the pull request's current head commit.
_Avoid_: Old review

**Published review thread**:
A GitHub pull request review thread containing feedback authored by Copilot. A thread remains actionable until it is resolved.
_Avoid_: Comment

**Suppressed comment**:
A Copilot finding published inside a pull request review body instead of as a review thread.
_Avoid_: Unpublished comment

**Unpublished finding**:
A Copilot finding visible only in internal session activity or execution logs and absent from the published pull request review.
_Avoid_: Suppressed comment
