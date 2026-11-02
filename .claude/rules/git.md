# Git

`MUST` = required, `SHOULD` = default, `MAY` = optional.

## Commits

- MUST: Stage named paths. Never `git add -A`, `--all` or `.`: it sweeps in work that is not
  this change's.
- MUST: Every message body goes through a file — `-F <file>` for a commit, `--body-file` for a pull
  request. Never `-m` with prose in it: backticks in a shell argument run as commands, and these
  bodies are full of `identifiers`.
- SHOULD: Put why and the measured numbers in the body.

## Never do these without being told

```text
git push --force          git reset --hard          git clean -fd
git checkout -- .         git checkout <path>       git restore . / <path>
gh pr merge --auto        gh pr merge --admin       a commit or push straight to main
```

A single path is not a smaller version of these: `git checkout <path>` throws away every
uncommitted edit in that file, not only the one you meant to undo.

- MUST: To undo a deliberate edit, restore the copy you took before making it. Commit before
  mutating anything, so that git's last known state is the state you meant.
- MUST: When one of these is genuinely needed, say what will be lost, first.
- MUST: Never discard or overwrite uncommitted work that is not yours. A modification you do not
  remember making is not yours until something says it is.
- MUST: Another agent may be working in the main checkout. Work in your own worktree and branch,
  and never touch a branch you did not create.

`.claude/settings.json` denies the usual spellings of these. A deny rule matches the command's text,
so another spelling can pass it; this file binds whether or not a pattern catches the command.

## Stacked pull requests

- MUST: Before merging, look at what is based on the branch (`gh pr list --json
  number,baseRefName`). If anything is, merge without `--delete-branch`: deleting a base branch
  closes the pull request on top of it, and a closed one cannot be retargeted.

## Before starting

- MUST: Look at the current branch and at uncommitted changes.
- MUST: Re-run the checks after a merge or rebase.

## Never put the working environment into anything that may be published

A repository's visibility can change; its history is not re-reviewed when it does. So in commits,
pull requests, issues and every tracked file:

- MUST NOT: An AI working-session URL, a local absolute path (`/home/<name>/…`), a hostname or an
  internal URL.
- MUST NOT: A token, a webhook or an API key.
- MUST: Write an issue or pull request with its repository name (`owner/repo#N`).
- MUST: Fixing a pull request body does not fix the squashed commit's body. If something leaked,
  say so to the owner; erasing it from history needs a force push, which is the owner's.
