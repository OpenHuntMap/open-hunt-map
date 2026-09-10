# AI guidelines

AI assistance is optional. Humans must be able to contribute without it.

Agents read [`AGENTS.md`](../AGENTS.md) at the repo root automatically; it holds
the working instructions, repo map, and commands. This page is the human-facing
policy behind it. Reusable agent workflows live in `.agents/skills/`, the
vendor-neutral location, so they are not tied to one editor.

## Before any AI-assisted work

1. Read [constraints.md](constraints.md) and [architecture.md](architecture.md).
2. Confirm the task does not require servers, paid APIs, cloud sync, or in-app AI.

## How to use AI well

- **Chunk tasks** — one layer, one screen, or one doc section per session.
- **Minimal diffs** — match existing patterns; no speculative abstractions.
- **Never add** cloud backends, paid map services, login, sync, or AI orchestration layers.
- **Land Info stays offline** — identify + report sheet + optional bundled PDFs only; no live policy lookup APIs.

## Review checklist

- [ ] Works offline with bundled/downloaded pack
- [ ] No new network dependency for core paths
- [ ] Province data under `data/{cc}/` conventions
- [ ] Sample data only in git; large packs documented for Releases

Reject suggestions that trade constraints for convenience.
