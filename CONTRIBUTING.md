# Contributing

Issues and pull requests are welcome.

Everything in this repository is prose an agent reads and acts on, so the
writing is the product. Three conventions govern it, and the validator can only
see the third.

## Write it through the humanizer skill

Put new or reworded text through the
[`humanizer` skill](https://github.com/anthropics/skills) before you commit it.
That covers `SKILL.md`, the reference sections, the README, `AGENTS.md`, this
file, commit messages and pull request descriptions. If your tool cannot run the
skill, work from Wikipedia's
["Signs of AI writing"](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing),
which is what it is based on.

It catches what the validator cannot see:

- A point staged rather than stated, usually as a contrast against something
  nobody claimed.
- A list padded out to three items because three sounds finished.
- A claim inflated past what was verified, or a ranking nothing in the text
  supports.
- A closing line that repeats the paragraph above it.

A reference that reads like a sales page is a reference an agent will summarise
back at you instead of following.

## Write forwards, not against

Say what to do and why it works. Do not frame the skill, or a section of it,
against what went wrong somewhere else: no origin stories about a painful
build, no lists of what someone got wrong before, no characterising upstream or
another project as careless.

The reason is practical rather than diplomatic. A sentence about a past mistake
carries no instruction, so an agent reading it has nothing to act on, and a
reader who does not share the history cannot tell which parts still apply.
"Leaving `allowed_domains` blank removes the framing restriction" is usable on
any release. "We learned the hard way that blank domains bite" is not.

This applies to prose, headings, commit messages and pull request descriptions.
Two things it does not forbid:

- Naming a specific upstream behaviour, with the release it was read in, and
  saying plainly what it does. That is the substance of this skill.
- Recording that something was tried and did not work, where the alternative is
  the recommendation. Say what was measured and what followed from it, and skip
  the narrative.

## Run the validator

```bash
node tools/validate.mjs
```

It checks the skill's frontmatter against the Agent Skills spec, that `SKILL.md`
stays under 500 lines, that every reference exists and is reachable, that the
links and anchors between files resolve, the ban on em and en dashes, that no
value from the installation this skill was cut from has travelled with it, that
the marketplace manifest matches the repository, and that there is exactly one
`SKILL.md`. CI runs it on every pull request.

Two of those checks exist because the thing they check for shipped once, and
both are worth keeping in mind when you edit:

- The reference table's line counts have to be the real ones. They exist so an
  agent can budget a read, and an agent that finds the first number wrong has no
  reason to trust the next one. Update them in the same commit as the prose, or
  the build fails.
- Every variable a template refers to has to be one `env.template` defines. An
  absent variable is not an untested design, it is a template that cannot start,
  and the unfilled-placeholder grep in `install.md` cannot catch it because
  there is nothing there to be unfilled. `STAGING_IMAGE` is the one allowed
  exception, because it is set per run rather than stored.

## Claims

This skill came from one installation, read against one release of Chatwoot. So
every claim in it names the version it was checked at, and where the behaviour
lives in the source. If you add a claim, say which release you read and how you
confirmed it.

Chatwoot changes these behaviours without announcing them, and none of them are
a documented contract. A claim carried over from an older release, with no
version attached, is worse than no claim: someone will build on it after it has
stopped being true.

Anything you could not confirm goes in
[claims that were not verified](chatwoot-self-hosting/references/verification.md),
not into the prose with a hedge in front of it.

## Providers

One topology was built and measured. The second is written from the
requirements, and it says so wherever it appears. Keep that line visible. If you
verify the second topology, or add a third, replace the label with what you ran
and what you observed rather than removing it.

Do not name a provider as a requirement. The requirements tables say what a
component must supply, and a provider is an example of something that supplies
it.

## Security writing

The widget vulnerability is publicly disclosed and unpatched upstream, so the
mitigation belongs in the open. Describe the mechanism and the fix. Do not add a
working exploit, a copy-pasteable payload, or steps that read as an attack
recipe. The forged message test is a regression check and belongs where it is.
