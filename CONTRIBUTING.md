# Contributing

Thanks for reviewing/hacking on monerotor. It's a security tool — clarity and
correctness beat features.

## Ground rules

- **Preserve the security invariants** in `DEVELOPMENT.md`. PRs that add a published
  port, widen the capability set, add any remote-management path, reintroduce
  backup/restore (or any code that unpacks operator-supplied files), or weaken
  the kill-switch will be declined unless they come with a threat-model update
  and a very good reason.
- **POSIX sh only** in `bin/` (busybox ash target). `shellcheck -s sh bin/*` must
  pass. `hadolint Dockerfile` must pass.
- Keep files small and commented with *why*, not *what*.

## Dev loop

```sh
shellcheck -s sh bin/*        # lint
hadolint Dockerfile           # lint
docker compose build          # build
docker compose run --rm -it setup   # exercise the wizard
docker compose up -d          # run
```

## Before opening a PR

- Run the **test checklist** in `DEVELOPMENT.md`.
- Update `THREAT_MODEL.md` if you change the security posture.
- Update `DEVELOPMENT.md` invariants/roadmap if the design shifts.

## Reporting security issues

Please disclose responsibly (open a private advisory / contact the maintainers)
rather than a public issue for anything that could deanonymize an operator.
