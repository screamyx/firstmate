# Herdr isolation - HARD SAFETY CONTRACT
This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.
On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.
A named non-`default` session plus an explicit `--session <name>` Herdr option on every call is the only viable local isolation.

For tmux-based lab primaries, `bin/fm-lab-home.sh` owns the short private socket directory; do not place `TMUX_TMPDIR` under the lab home or worktree.
Use `LAB_HOME_HELPER='{run-worktree}/bin/fm-lab-home.sh'`, then `LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")` and launch tmux with `TMUX_TMPDIR="$LAB_TMUX_DIR"`.
Your single EXIT cleanup trap must kill only that server, by its explicit socket (`tmux -S "$LAB_TMUX_DIR/tmux-$(id -u)/<socket-name>" kill-server`) and only while that socket exists, never through `TMUX_TMPDIR` alone, which silently falls back to the default tmux server once the directory is gone; it must also call `"$LAB_HOME_HELPER" teardown "$FM_HOME"` and, in a Herdr 1 lab, the Herdr teardown below; do not install a second trap that replaces either cleanup.

1. Set `HERDR_LAB_HELPER='{run-worktree}/bin/fm-herdr-lab.sh'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name t1)`.
   Install the combined EXIT cleanup before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.
2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.
   The helper supplies the required `--session "$HERDR_LAB_SESSION"` as a Herdr option, before any `--` delimiter; `HERDR_SESSION` alone is never accepted as isolation.
3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.
   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.
4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.
5. Forbidden commands: direct `herdr server stop`, `hc server stop`, `hc server restart`, `herdr-core server stop`, `herdr-core server restart`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.
6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.
   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.

Rules 1-4 and 6 and the helper apply to Herdr 0.7.3 (Herdr 1) labs; never bypass the helper there, even for a read-only lifecycle probe or cleanup after failure.
A Herdr 2 / herdr-app lab with its own scratch `hc` cores needs neither the Herdr 1 CLI nor its default session, but rules 5 and 7-9 bind it as they bind every lab.

7. An inherited `HC_SOCKET` (or any other socket override) beats `HC_SESSION`, so every `hc` call in a lab, whatever the operation, must reach only the lab's own scratch core; the `default` session is never addressed.
   Clear any inherited override and pin the lab's own scratch socket and session on that same call: `env -u HC_SOCKET HC_SESSION=<lab session> HC_SOCKET=<lab scratch socket> hc ...`; `'{run-worktree}/bin/fm-hc-lab.sh' run <lab session> <hc arguments...>` does this for a core it provisioned.
8. Heredocs in lab work use a quoted delimiter (`<<'EOF'`), because an unquoted one runs backtick text as commands; this triggered the 12:22 crash that stopped the main herdr-core.
9. Run your own herdr-core tripwire, helper or not.
   Before any lab record the `herdr-core.service` MainPID (`systemctl --user show -p MainPID --value herdr-core.service`, only where `systemctl --user` works) and whether the default core socket exists; no service or no live core is a valid baseline, recorded as such.
   After the lab read the same values.
   A different MainPID, a MainPID that went empty, a MainPID that went from empty to a value, a default core socket that was present and is now gone, or a default core socket that was absent and now exists is a hard failure: report it at once.
   The same values before and after, including empty both times, pass; without systemd the socket check alone is the tripwire.
The captain fleet uses the running `default` session.
