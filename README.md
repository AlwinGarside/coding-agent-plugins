# Alwin Garside's Coding Agent Plugins

## Instalation

```bash
codex plugin marketplace add AlwinGarside/agent-plugins
```

or

```bash
claude plugin marketplace add AlwinGarside/agent-plugins
```

## Plugins

### Github Utils

```
codex plugin add github-utils@AlwinGarside
```

or

```
claude plugin install github-utils@AlwinGarside
```


#### [Babysit a GitHub PR](plugins/github-utils/skills/babysit-github-pr/SKILL.md)

```
github-utils:babysit-github-pr
```

Monitor a GitHub PR for feedback until it has enough approvals and all outstanding feedback is resolved.

#### [Push to GitHub and babysit `@copilot`](plugins/github-utils/skills/push-to-github-and-babysit-copilot/SKILL.md)

```
github-utils:push-to-github-and-babysit-copilot
```

Push changes to a GitHub repo, ensure a PR exists and monitor it for feedback from `@copilot`.
