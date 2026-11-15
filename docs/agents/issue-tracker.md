# Issue tracker

Use GitHub Issues in the repository you are working in for requests and specs.
Pass the repository explicitly when running GitHub CLI commands outside its checkout.

- Read an issue with `gh issue view <number> --json number,title,body,labels,comments`.
- Create an issue with `gh issue create --title "..." --body-file <file>`.
  Use `--body-file` for multiline edits and comments too.
- Create a child issue with `gh issue create --parent <parent>`, or link an
  existing child with `gh issue edit <parent> --add-sub-issue <child>`.
- Record a blocker with `gh issue edit <child> --add-blocked-by <blocker>`.
  Check open blockers with
  `gh api repos/OWNER/REPO/issues/<number> --jq .issue_dependencies_summary.blocked_by`.

If you cannot create native relationships, add `Part of #<parent>` and
`Blocked by #<blocker>` where applicable in the child issue. List the child in
the parent's task list.
