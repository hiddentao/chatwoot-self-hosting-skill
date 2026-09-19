#!/usr/bin/env node
// Checks this repo against the Agent Skills spec and its own conventions.
// Wired into CI, because a check nobody runs stops being a check.
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";
const SKILL_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../chatwoot-self-hosting");
const ORDER = ["providers", "install", "widget-security", "inboxes-and-identity",
               "email", "hardening", "upgrades", "verification"];

// The skill was cut from one operator's live installation. These are the values
// that must not have travelled with it. A hostname, a cluster, a bucket, an
// address range and a key name each identify that installation; the repository
// URL is the one place the owner's name belongs.
const LEAKS = [
  /hezo/i,
  /hiddentao/i,
  /db-postgresql-lon1-\d+/i,
  /\b187\.40\.240\b/,
  /opentofu/i,
  /sha384-XJckvmLqv7fv/,
];
const LEAK_ALLOWED = /github\.com\/hiddentao/gi;

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fail = [];
const check = (ok, msg) => { if (!ok) fail.push(msg); };
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9 -]/g, "").replace(/ /g, "-");
// Newline count, so these agree with what `wc -l` reports.
const lines = (text) => (text.match(/\n/g) || []).length;

// --- frontmatter, against the published spec -------------------------------
const spine = readFileSync(`${SKILL_DIR}/SKILL.md`, "utf8");
const fm = spine.match(/^---\n([\s\S]*?)\n---\n/);
check(!!fm, "SKILL.md has no YAML frontmatter");
if (fm) {
  const name = fm[1].match(/^name:\s*(.+)$/m)?.[1]?.trim();
  const desc = fm[1].match(/^description:\s*(.+)$/m)?.[1]?.trim();
  check(!!name, "frontmatter: name missing");
  check(!!desc, "frontmatter: description missing");
  if (name) {
    check(/^[a-z0-9-]+$/.test(name), `name "${name}" must be lowercase letters, digits, hyphens`);
    check(!/^-|-$|--/.test(name), `name "${name}" cannot lead/trail or double a hyphen`);
    check(name.length <= 64, `name is ${name.length} chars, max 64`);
    check(!/anthropic|claude/i.test(name), `name "${name}" uses a reserved word`);
    check(name === basename(root) || `${name}-skill` === basename(root),
      `name "${name}" should match the skill directory it installs as`);
  }
  if (desc) {
    check(desc.length <= 1024, `description is ${desc.length} chars, max 1024`);
    check(!/[<>]/.test(desc), "description cannot contain angle brackets");
  }
}

// An agent reads SKILL.md on every use, so it stays short enough to be read.
check(lines(spine) <= 500, `SKILL.md is ${lines(spine)} lines, max 500`);

// --- every reference exists and is reachable -------------------------------
const refs = readdirSync(`${SKILL_DIR}/references`).filter((f) => f.endsWith(".md"));
check(refs.length === ORDER.length, `references/ has ${refs.length} files, expected ${ORDER.length}`);
for (const name of ORDER) check(existsSync(`${SKILL_DIR}/references/${name}.md`), `missing references/${name}.md`);

// --- the routing table's line counts are the real ones ----------------------
// They exist so an agent can budget a read. A stale number is worse than none,
// because the agent has no way to tell which of them it can still trust.
for (const name of ORDER) {
  const actual = lines(readFileSync(`${SKILL_DIR}/references/${name}.md`, "utf8"));
  const row = spine.match(new RegExp(`^\\|\\s*\\[${name}\\]\\(.*?\\|\\s*(\\d+)\\s*\\|`, "m"));
  if (!row) { fail.push(`SKILL.md: no reference-table row for ${name}`); continue; }
  check(Number(row[1]) === actual,
    `SKILL.md: reference table says ${name} is ${row[1]} lines, it is ${actual}`);
}

// --- cross-file links resolve ----------------------------------------------
const files = [["SKILL.md", spine], ...refs.map((f) => [`references/${f}`, readFileSync(`${SKILL_DIR}/references/${f}`, "utf8")])];
const anchors = new Map(files.map(([f, t]) =>
  [f, new Set([...t.matchAll(/^#{1,6} (.+)$/gm)].map((m) => slug(m[1])))]));
for (const [file, text] of files) {
  for (const [, target, anchor] of text.matchAll(/\]\(((?:\.\.\/)?(?:references\/)?[a-zA-Z-]+\.md)?(#[a-z0-9-]+)?\)/g)) {
    let owner = file;
    if (target) {
      const base = basename(target);
      owner = base === "SKILL.md" ? "SKILL.md" : `references/${base}`;
      check(anchors.has(owner), `${file}: link to missing file ${target}`);
    }
    if (anchor && anchors.has(owner)) {
      check(anchors.get(owner).has(anchor.slice(1)), `${file}: dead anchor ${target ?? ""}${anchor}`);
    }
  }
  check(!/[—–]/.test(text), `${file}: contains an em or en dash`);

  // Prose wraps at 80. Fenced code is quoted verbatim and must not be reflowed,
  // table rows have nowhere to break, and a bare link cannot wrap at all. This
  // rule exists because editing a sentence in place without rewrapping the
  // paragraph around it is the easiest way to lose the wrap, and it happened
  // three times in one afternoon.
  let fenced = false;
  // The frontmatter's description is one line by spec and cannot be wrapped.
  let frontmatter = text.startsWith("---\n");
  text.split("\n").forEach((line, i) => {
    if (frontmatter) { if (i > 0 && line === "---") frontmatter = false; return; }
    if (/^\s*```/.test(line)) { fenced = !fenced; return; }
    if (fenced || line.length <= 80) return;
    if (/^\s*\|/.test(line)) return;                     // table row
    if (/^\s*\[[^\]]+\]:\s*\S+$/.test(line)) return;     // link definition
    if (/^\s*\S+$/.test(line)) return;                   // one unbreakable token
    fail.push(`${file}:${i + 1}: prose line is ${line.length} columns, max 80`);
  });
}

// --- every variable a template needs is one env.template defines ------------
// An absent variable is not an untested design, it is a broken template, and
// the unfilled-placeholder grep cannot catch it because there is nothing there
// to be unfilled. This check exists because that shipped once.
{
  const TPL = `${SKILL_DIR}/tools/templates`;
  // Set on the command line for one run, deliberately not in the env file.
  const EXTERNAL = new Set(["STAGING_IMAGE"]);
  const defined = new Set(
    [...readFileSync(`${TPL}/env.template`, "utf8").matchAll(/^([A-Z][A-Z0-9_]*)=/gm)]
      .map((m) => m[1]));
  for (const f of readdirSync(TPL)) {
    if (f === "env.template") continue;
    const text = readFileSync(`${TPL}/${f}`, "utf8");
    // ${VAR}, ${VAR:?...}, ${VAR:-...} in compose; {$VAR} in a Caddyfile.
    const used = new Set([
      ...[...text.matchAll(/\$\{([A-Z][A-Z0-9_]*)[:}]/g)].map((m) => m[1]),
      ...[...text.matchAll(/\{\$([A-Z][A-Z0-9_]*)\}/g)].map((m) => m[1]),
    ]);
    for (const v of used) {
      if (EXTERNAL.has(v) || defined.has(v)) continue;
      fail.push(`tools/templates/${f}: needs ${v}, which env.template does not define`);
    }
  }
}

// --- nothing from the installation this was cut from ------------------------
(function walk(d) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (e.isDirectory()) { walk(`${d}/${e.name}`); continue; }
    if (/\.(png|jpg|jpeg|gif|webp|ico|zip)$/i.test(e.name)) continue;
    const text = readFileSync(`${d}/${e.name}`, "utf8").replace(LEAK_ALLOWED, "");
    const rel = `${d}/${e.name}`.slice(root.length + 1);
    for (const pattern of LEAKS) {
      const hit = text.match(pattern);
      if (hit) fail.push(`${rel}: leaks "${hit[0]}" from the source installation`);
    }
  }
})(SKILL_DIR);

// --- exactly one SKILL.md inside the skill directory ------------------------
// The Skills API and claude.ai reject an upload containing more than one, so a
// stray SKILL.md anywhere under the skill directory breaks installation there.
const nested = [];
(function walk(d) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (e.isDirectory()) walk(`${d}/${e.name}`);
    else if (e.name === "SKILL.md") nested.push(`${d}/${e.name}`);
  }
})(SKILL_DIR);
check(nested.length === 1, `skill directory holds ${nested.length} SKILL.md files, must hold exactly 1`);

// --- the marketplace manifest matches the repo -----------------------------
const mkt = JSON.parse(readFileSync(`${root}/.claude-plugin/marketplace.json`, "utf8"));
check(mkt.name === basename(root), `marketplace name "${mkt.name}" should match the repo directory`);
check(!/^(agent-skills|anthropic-marketplace|anthropic-plugins|claude-code-marketplace|claude-code-plugins|claude-plugins-official)$/.test(mkt.name),
  `marketplace name "${mkt.name}" is reserved`);
check(Array.isArray(mkt.plugins) && mkt.plugins.length > 0, "marketplace has no plugins");

if (fail.length) {
  console.error(`FAIL (${fail.length})`);
  for (const f of fail) console.error(`  - ${f}`);
  process.exit(1);
}
console.log("OK: frontmatter, references, links, manifest and scrubbing all valid");
