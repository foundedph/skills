---
name: blast-radius
description: "Find what a change could break outside its own diff, and prove the one fact it is safe because of by running real code. Use when the user asks for the blast radius of a change, asks what a diff or PR could break, or wants a small diff they don't trust checked before merge or deploy."
metadata:
  credits:
    skill: blast-radius
    author: Lauren Tan
    organisation: Cursor
    url: "https://github.com/cursor/plugins/blob/1dcc2ba/pstack/skills/blast-radius/SKILL.md"
---

<!-- SOURCE: cursor/plugins@1dcc2ba pstack/skills/blast-radius (MIT (c) Lauren Tan). LOCAL DELTA (2026-10-14): model-invoked instead of user-invoked; `how`/`why`/`arena`/`unslop` references replaced with git/gh, reviewer-deep and codex-adversarial.sh. Keep across upstream re-syncs. -->

# Blast radius

Find what a change breaks somewhere else, before it ships.

Listing the callers is not the job. Grep finds those in a second. The job is the breakage grep won't show you.

## Don't trust your own writeup

A blast-radius writeup that sounds right is worthless: it reads as convincing whether or not it is true. So don't hand back only the writeup. Find the one or two facts the change's safety depends on and prove them by running code.

### How sure are you

For each fact the safety depends on, push it as far down this ladder as is cheap, and say where it stopped.

1. You said so. Worthless on its own.
2. You pointed at the line: a real `file:line`, or the library's own source.
3. You showed the bad case can't happen: you walked the failure step by step and it doesn't reach.
4. You ran it: a script or test that calls the real code and fails loud if you're wrong.
5. You reproduced it in the running app.

Step 4 is usually one small script that imports the same library the app ships and calls the exact function you're worried about.

## Steps

1. **Read the change.** The diff, the symbols it adds, changes and deletes, and what it now does differently, including the part the diff doesn't spell out. Pull context with `git log -p`, `git blame`, and `gh pr view <n> --comments` when there is a PR.
2. **Find the one fact it's safe because of.** Most changes that look risky are safe because of a single fact, like "this call only drops already-dead cache entries". Find that fact. If it holds, most risky cases clear at once. Spend your time here, not on a long list of maybes.
3. **Look where grep stops.** Read the source of the library you call, and check its pinned version and any local patch. Work out when things run: microtasks, unmount and teardown, request lifecycle, transactions. Follow what a symbol search misses: the JSON an API returns, a DB column, RLS policies and triggers, a wire format, another service or language reading the same bytes, a feature flag, code three hops downstream.
4. **Be honest about each risk.** Give it a real likelihood and a real cost. Keep the risks you confirmed; list the ones you checked and cleared separately. Cite a real `file:line`. A search that finds nothing is still an answer. Never make up a caller or an API.
5. **Prove the one fact.** Write a script or test that runs the real code, run it, and paste what happened.
6. **For a big or wide change, get a second model.** If the repo has a `review-route.sh` and it returns `opus`, have the `reviewer-deep` agent re-check your risks, and run `~/.claude/scripts/codex-adversarial.sh` when it reports `adversarial=codex`. Treat what they return as claims to verify, not verdicts. Different models catch different real bugs.

## What to hand back

- **What it does.** What changed, including the part that isn't obvious.
- **The one fact it's safe because of.** State it, say which ladder step you got it to, and show the proof. If you couldn't prove it, write **unproven**.
- **Risks.** Each names how it breaks, the `file:line`, how likely and how bad, and how to check. Paste the proof for the ones that matter.
- **Cleared.** What you checked and why it's fine.
- **Before you merge.** The cheapest test or repro that catches the real bug, including the script you wrote.

Cite real code, keep it plain, and strip anything private before it goes anywhere public.
