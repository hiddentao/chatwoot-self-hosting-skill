# Chatwoot Self-Hosting

An [Agent Skill](https://agentskills.io) that teaches coding agents to deploy,
harden and run a self-hosted [Chatwoot](https://www.chatwoot.com) installation.
The installation keeps its admin console off the public internet, serves a
widget SDK patched against a disclosed and unfixed vulnerability, locks every
chat widget to the sites allowed to embed it, and survives upgrades because
every release is pinned and rehearsed first.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Validate](https://github.com/hiddentao/chatwoot-self-hosting-skill/actions/workflows/validate.yml/badge.svg)](https://github.com/hiddentao/chatwoot-self-hosting-skill/actions/workflows/validate.yml)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-spec%20compliant-7c3aed)](https://agentskills.io/specification)

## What this is

A default Chatwoot Community Edition installation leaves four things for the
operator to close: an endpoint that creates an administrator without asking who
you are, an admin console that takes a password and no second factor, a chat
widget any website can embed, and a widget script carrying a published
vulnerability that Chatwoot has not fixed. None of them announce themselves, and
a working installation looks the same either way.

The skill gives an agent eleven rules, eight reference files and a set of
working files: the widget patch and the script that builds and tests it, the
Chatwoot console scripts, compose and proxy templates, an outside-in checker,
and a probe that asks eight questions of whatever stack you are considering.

Everything was checked against Chatwoot 4.17.1 by reading the source at that
tag, and every claim says so.

## The eleven rules

1. **Pin an exact image digest.** A moving tag updates on every commit to
 Chatwoot's main branch, and database migrations never run by themselves. You
 end up with new code on an old database and no error to tell you.
2. **Finish setup before the address works.** The first-run page makes whoever
 fills it in an administrator, and it asks nothing about who they are. It comes
 back whenever the database is empty, so a restore reopens it. Do the first run
 over an SSH tunnel and publish DNS after.
3. **Read the flags literally.** Turning signup off with `off`, `0` or `f`
 leaves it on, because the code compares against the word `false`. Check the
 setting in the database, where the real value lives.
4. **Keep the admin console private.** It accepts a password and asks for no
 second factor, unlike the normal login. Make your proxy return 404 for it.
5. **Serve your own copy of the widget script.** The shipped one accepts
 messages from any window on the page and will hand a visitor's chat session to
 whoever asks. One patched file on your own server fixes it, with no fork.
6. **Lock each widget to its own sites, and require signed visitors.** Leaving
 the domain list empty does not fail safe: it lets any website embed your chat.
7. **Identity comes from your app, not from a cookie.** Widening the chat cookie
 to cover subdomains shares a live session with all of them. Sign an identifier
 your application owns, and never use an email address for it.
8. **Decide the email compromise up front.** Chat transcript emails all come
 from one address for the whole account, and there is no per-widget sender.
 Receiving replies needs a second mail provider.
9. **Assign conversations with a rule.** The built-in round-robin only picks
 agents who are online right now, so a one-person queue gets nothing assigned
 exactly when nobody is watching.
10. **Rehearse every upgrade on a copy of the data.** There is no way back down
 a migration. The only recovery is restoring the database.
11. **Check from outside and in the database.** The outside tells you what an
 attacker sees. The database tells you what the dashboard will not show you.

## Install

This skill follows the [Agent Skills specification](https://agentskills.io/specification),
so you install it the same way in every tool: copy the `chatwoot-self-hosting`
directory into the folder where your tool looks for skills. Do not rename the
directory. The spec requires it to match the skill's name.

```bash
git clone https://github.com/hiddentao/chatwoot-self-hosting-skill.git
```

Then copy the skill directory to the right place:

| Tool | Project-level | User-level |
| --- | --- | --- |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Codex CLI, ChatGPT desktop | `.agents/skills/` | `~/.agents/skills/` |
| Cursor | `.cursor/skills/` | `~/.cursor/skills/` |
| GitHub Copilot, VS Code | `.github/skills/` | `~/.copilot/skills/` |
| Gemini CLI, Zed | native skills support | see tool docs |

For example, for Claude Code:

```bash
mkdir -p ~/.claude/skills
cp -r chatwoot-self-hosting-skill/chatwoot-self-hosting ~/.claude/skills/
```

To get updates with `git pull`, use a symlink instead:

```bash
ln -s "$PWD/chatwoot-self-hosting-skill/chatwoot-self-hosting" ~/.claude/skills/
```

The paths in this section come from each tool's documentation.

### Claude Code plugin

Run these two commands in a shell, or as slash commands in a session:

```bash
claude plugin marketplace add hiddentao/chatwoot-self-hosting-skill
claude plugin install chatwoot-self-hosting@chatwoot-self-hosting-skill
```

### claude.ai and the Claude desktop app

The chat apps install skills from a zip file:

1. Settings, then Capabilities, and enable code execution and file creation.
2. Customize, then Skills, then **+**, then Create skill, then Upload a skill.
3. Choose a zip that has the skill folder at its root.

```bash
cd chatwoot-self-hosting-skill
zip -r chatwoot-self-hosting.zip chatwoot-self-hosting/
```

The zip must contain exactly one `SKILL.md`. The skill is plain Markdown, so
enterprise organisations can upload it too.

### Any other agent

Most tools without skills support read [AGENTS.md](https://agents.md). Copy
[`AGENTS.md`](AGENTS.md) to your repo root. It has a short version of the rules.
For the full detail, copy the skill directory into your repo so your agent can
open the [references](chatwoot-self-hosting/references/) when it needs them.

For Aider, add `read: AGENTS.md` to `.aider.conf.yml`. Continue reads rules from
`.continue/rules/`.

## Asking your own stack

The rules are Chatwoot behaviour, and they hold wherever you run it. What
changes between providers is what your database, object store, mail provider and
edge actually do, and those answers move without being announced. So the skill
ships a probe that asks them:

```bash
PGURL='...' S3_ENDPOINT='...' S3_BUCKET='...' \
  chatwoot-self-hosting/tools/probe-stack.sh
```

It reports what it could measure and prints `NOT MEASURED`, plus the measurement
to go and take by hand, for what it could not. A managed database on an
unexpected port, a missing Postgres extension, a statement timeout that will
kill your first migration, and an edge that lets a client choose its own address
are all things it will tell you before you install anything.

Two topologies are described. Managed Postgres with object storage behind a
proxying edge is the one that was built and measured. A single box running
everything is written from the requirements and labelled throughout as not
verified.

## How it is laid out

`chatwoot-self-hosting/SKILL.md` holds the eleven rules, the build order, the
provider requirements and the trap table in under 500 lines. The eight files in
`references/` each cover one topic in depth, and `tools/` holds the widget
patch, the console scripts, the templates and the probes.

An agent reads `SKILL.md` every time it uses the skill, so the spec asks for it
to stay under 500 lines and the validator enforces it. The references add about
3,500 lines, and the agent reads each one only when a task needs it.

The widget patch is shipped as a patch, and the built script is not. You build
it against the release you pinned, and the build script refuses to write
anything unless an unmodified build first reproduces the file Chatwoot shipped,
byte for byte.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers
the writing conventions, including running the `humanizer` skill over any prose
you add, and the validator that every change has to pass.

```bash
node tools/validate.mjs
```

The validator also checks that nothing from the installation this skill was cut
from has travelled with it.

## License

[MIT](LICENSE).
