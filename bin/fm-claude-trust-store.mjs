// Atomic read-modify-write of Claude Code's project trust store for bin/fm-claude-trust.sh.
// Usage: node fm-claude-trust-store.mjs <store> <mode> <target> <project> <trust-flag> <import-flags-json>
// Modes: worktree (target + project entries), anything else (target entry only).
// The caller has already proved the scope; this only writes. Notes on the write:
// Read-modify-write, then read back and confirm. fm-spawn runs from a live
// firstmate Claude Code session that writes this same file, so the store can move
// under us in both directions and each needs its own answer.
//
// Losing the VENDOR's write is the serious one: this renames a whole
// re-serialisation over the file, so anything Claude changed since the read -
// oauthAccount, user-scope mcpServers, another project's history - would be gone,
// in a format this does not own. So the bytes read are fingerprinted and
// re-checked immediately before the rename, and a store that moved is not
// overwritten: the whole read-modify-write is retried once, and a second move
// refuses rather than clobbering.
//
// That narrows the window; it does not close it. Rename cannot be conditioned on
// content, so a write landing between the final check and the rename is still
// lost, and this claims no more than that.
//
// Losing OUR entry is the mild one: a vendor rewrite that drops it only resurrects
// the dialog this registration removes, which reaches firstmate as an ordinary
// stale wake and a relaunch registers again. The readback catches it within these
// attempts, and it must fail loudly rather than report a trust it did not leave.
// ponytail: fingerprint-and-refuse, not a lock; flock is absent on macOS and
// cannot stop a vendor session's own rewrite anyway.
//
// In worktree mode every flag lands on both the worktree entry and the project
// entry in the same read-modify-write attempt, so a single rename either
// records all of it or none of it - there is no state where the worktree entry
// is fresh and the project entry stale, or the other way round. In
// secondmate-home mode only the single home entry is written.
//
// The two external-imports flags (worktree mode only) are gated separately
// from the trust flag, because they are a CONSENT grant, not a pre-approval
// this script is allowed to manufacture. Claude Code only ever writes
// hasClaudeMdExternalIncludesApproved===true itself, on an explicit interactive
// answer; this script's own job is to keep a worker from wedging on a dialog,
// never to answer that dialog on the human's behalf. So the import flags land
// on the project entry - the only place the imports check ever reads (see the
// disassembly note above) - only when that entry ALREADY carries
// hasClaudeMdExternalIncludesApproved===true, i.e. the human already said yes
// at some point and this write is a same-value refresh, not new consent from
// an absent flag. When it is not already true (including plain absent, the
// common case for a project claude has never asked about), the import flags
// are left untouched on both entries: writing them to the worktree entry alone
// would be a pure no-op (the imports check never reads it) that only obscures
// the real state, so trust still registers normally but the import dialog is
// left exactly as undecided as it already was - the worker wedges on it, the
// same honest outcome as an explicit decline, rather than a spawn spending
// consent the human was never asked for.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
const [store, mode, target, project, trustFlag, importFlagsJson] = process.argv.slice(2);
const importFlags = JSON.parse(importFlagsJson);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const setFlags = (projects, key, flags) => {
  let entry = projects[key];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  for (const flag of flags) entry[flag] = true;
  projects[key] = entry;
};
const flagsLanded = (projects, key, flags) =>
  flags.every((flag) => projects?.[key]?.[flag] === true);
// The project entry is the launching user's OWN interactive config, not a
// throwaway worktree, so a spawn must never silently reverse a decision the
// human already recorded there. hasClaudeMdExternalIncludesApproved===false
// together with hasClaudeMdExternalIncludesWarningShown===true is exactly that
// decision (the dialog's "No, disable" answer writes that pair; Claude Code's
// default project entry carries Approved===false with WarningShown===false,
// which means never asked, not declined); flipping it to true would grant every future
// interactive session in that checkout silent external-file inclusion the
// human declined. Refuse the whole registration instead of overriding it -
// the worktree entry is not written either, so the spawn wedges on the
// dialog rather than the human's consent being spent without being asked.
const declinedExternalImports = (projects, key) =>
  projects?.[key]?.hasClaudeMdExternalIncludesApproved === false &&
  projects?.[key]?.hasClaudeMdExternalIncludesWarningShown === true;
// True only on an explicit prior "Yes, allow" answer - the sole state this
// script may treat as standing consent to refresh. Absent, or any other
// value, is NOT consent (see the block comment above this script's node call).
const approvedExternalImports = (projects, key) =>
  projects?.[key]?.hasClaudeMdExternalIncludesApproved === true;
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  let keys;
  if (mode === "worktree") {
    if (declinedExternalImports(projects, project)) {
      throw new Error(
        `project entry for ${project} in ${store} already declined external CLAUDE.md imports; refusing to override that consent. To recover, remove hasClaudeMdExternalIncludesApproved and hasClaudeMdExternalIncludesWarningShown from that project entry and approve the imports dialog interactively once`,
      );
    }
    const carryImportConsent = approvedExternalImports(projects, project);
    const targetFlags = carryImportConsent ? [trustFlag, ...importFlags] : [trustFlag];
    const projectFlags = carryImportConsent ? [trustFlag, ...importFlags] : [trustFlag];
    setFlags(projects, target, targetFlags);
    setFlags(projects, project, projectFlags);
    keys = [[target, targetFlags], [project, projectFlags]];
  } else {
    setFlags(projects, target, [trustFlag]);
    keys = [[target, [trustFlag]]];
  }
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  // Two-space pretty-printed, because that is the format Claude Code itself
  // writes: the store on the box this was measured on begins "{\n  " and runs
  // 9646 lines. Compact would reformat the operator's whole config on every
  // spawn and the vendor's next write would expand it again, so this must not
  // be "simplified" to JSON.stringify(root) without re-measuring the vendor.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  const landed = keys.every(([key, flags]) => flagsLanded(back.projects, key, flags));
  return landed ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${target}${project ? ` and ${project}` : ""} after 3 attempts`);
process.exit(1);
