# Round 2 live evidence (target b8fb488, base 72ec8e0)

All runs below were re-driven in this test round on this host (Claude Code 2.1.288, procps-ng 4.0.4, herdr 0.9.3).

## 1. Real Claude Code primary, Stop hooks at a 4x2 pane

Driver: ../lab-driver.sh (real `claude --model haiku` on the private tmux socket fm-lab, marked lab FM_HOME from bin/fm-lab-home.sh, plain clone of the run worktree so primary scope matches; only bin/fm-watch-arm.sh and bin/fm-wake-drain.sh are the bounded fixtures).
The pane is shrunk to 4x2 after session start and before the first turn ends, so Claude hands its Stop hooks COLUMNS=4 LINES=2.

| run | first Stop after CYCLE0 | hook-owned arm runs | arm env | auto-arm epoch ledger |
|---|---|---|---|---|
| live-base (72ec8e0) | TURN WOULD END BLIND - SUPERVISION IS OFF ... The Stop-owned auto-arm did not claim this home either | 0 | - | absent |
| live-target (b8fb488) | watcher wake `stale: fixture-rapid-1` (auto-arm claimed and armed) | 4 | COLUMNS=4 LINES=2 | epoch=2 outcome=clean |

Round-1 wide controls (../live-base-wide-control, ../live-target-wide-control, 200x50) show the same first-Stop wake as target-4x2.
The BLIND banner that follows the first ACK appears in the base wide control as well, so the fixture's third arm call causes it, not the width.

## 2. Herdr pane with a background harness, sampled at 4x2

Driver: ../herdr-lab-driver.sh through bin/fm-herdr-lab.sh (named fm-lab-pswidth-* session, provisioned and torn down).
See live-herdr/results.md: base at 4x2 samples `shell` (the false stale-agent path), target at 4x2 samples `agent`, and both trees sample `agent` at a wide width.

## 3. Adversarial: wider reads must not over-accept a lock owner

adversarial-session-lock-4x2.sh / .txt: real processes asked through fm_harness_pid_alive at COLUMNS=4 LINES=2.
Target at 4x2 returns exactly the base-at-COLUMNS=1000 verdict for every process: a claude stand-in is live, a plain sleep and a dead pid are not.
`claude-decoy` matching is the unanchored `claude` in FM_HARNESS_RE at full width (base wide agrees), not something this change introduces.

## 4. Remote job orphan reaper, dry run at 4x2

reaper-dry-run-4x2.sh / .txt: a real stand-in worker runs from a fixture code root that is then pruned, and `bin/fm-remote-job-reap-orphans.sh --dry-run` is run per tree and width.
Base at 4x2 reports no candidate (its unpinned scan line reads '/bin'), while target at 4x2 reports the abandoned worker exactly as both trees do at COLUMNS=1000.
The worker was still alive after every dry run, so nothing was signalled.

## Disclosures

- At 05:38:42 the target lab pane was resized to 160x40 to read it, after the 4x2 Stop had already fired. All four arm runs in live-target/state.txt record COLUMNS=4 LINES=2 and come from that first 4x2 window, so the claim proof is unaffected. The driver log only records the 4x2 resize.
- tests/fm-backend-herdr.test.sh was not re-run in this round. Round 1 ran it with the host-blocked /tmp/firstmate-herdr-presentation case skipped. The live Herdr lab above exercises fm_backend_herdr_pid_is_bare_shell on the product path.
