# Development workflow

- Work on `development` for ongoing development. Bundle changes there; do not merge or push to `main` unless the user explicitly requests a release.
- Pushing the development branch runs checks without publishing an update. Pushing `main` automatically publishes a signed release, so treat it as a release action.
- Use Git commands for commits, branches, merges, and pushes, as requested by the repository owner. Do not use a GitHub integration for these operations.
- Keep local builds signed with the existing persistent identity and install at `/Applications/LocalWrite.app`. Preserve the user's preferences and Accessibility authorization.
- Keep private keys, certificate exports, passwords, and other credentials out of source, logs, commits, and release artifacts.
