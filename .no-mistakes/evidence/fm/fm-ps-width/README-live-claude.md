# Live lab: Claude Code 2.1.288 interactive primary, Stop hooks at a 4x2 pane

Driver: lab-driver.sh (real claude --model haiku on private tmux socket fm-lab, marked lab FM_HOME, plain clone of the run worktree; only fm-watch-arm.sh/fm-wake-drain.sh are the bounded fixtures from tests/fm-claude-stop-autoarm-live-e2e.test.sh).

| run | pane at first Stop | hook-owned arm runs | arm env | epoch ledger | first Stop result |
|---|---|---|---|---|---|
| live-base | 4x2 | 0 | - | (absent) | TURN WOULD END BLIND - SUPERVISION IS OFF |
| live-target | 4x2 | 4 | COLUMNS=4 LINES=2 | epoch=2 outcome=clean | Stop hook feedback |
| live-base-wide-control | 200x50 | 4 | COLUMNS=200 LINES=50 | epoch=2 outcome=clean | Stop hook feedback |
| live-target-wide-control | 200x50 | 4 | COLUMNS=200 LINES=50 | epoch=2 outcome=clean | Stop hook feedback |

Base at 4x2 is the reported bug: the auto-arm never runs, no claim is written, and the guard reports 'TURN WOULD END BLIND - SUPERVISION IS OFF ... The Stop-owned auto-arm did not claim this home either'.
Target at 4x2 claims and arms on the first Stop exactly as both 200x50 controls do.
The later blind banner in target-4x2 and both wide controls appears after the fixture's third arm call removes task.meta and exits without a live watcher (arm runs 1 and 2 both fire on the first Stop with consecutive pids, consistent with the hook's handling successor consuming fixture run 2); it is width-independent and present at base.
