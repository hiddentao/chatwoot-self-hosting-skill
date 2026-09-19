---
name: chatwoot-self-hosting
description: Deploy, harden, operate and review a self-hosted Chatwoot installation. The installation keeps its admin console off the public internet, serves a widget SDK patched against a disclosed and unfixed CVE, locks every widget inbox to the sites allowed to embed it, signs visitor identities, and survives upgrades because every release is pinned and rehearsed. Use this skill for any self-hosted Chatwoot CE deployment, on any provider, with managed Postgres and object storage or on a single box. Also use it when someone mentions Chatwoot, a website inbox, a website token, HMAC identity validation, allowed domains, the widget sdk.js, chatwoot_prepare, Sidekiq, super admin, ENABLE_ACCOUNT_SIGNUP, transcript email, or asks why their widget can be embedded anywhere, why signup is still open after turning it off, or why a migration timed out. Read it before the first container starts, not after the installation is public.
license: MIT
metadata:
  repository: https://github.com/hiddentao/chatwoot-self-hosting-skill
---

# Self-hosted Chatwoot

A default Chatwoot Community Edition installation leaves four things for the
operator to close: an unauthenticated endpoint that mints a confirmed super
admin, an admin console with no second factor, a widget any site may embed, and
a widget SDK carrying a disclosed vulnerability with no upstream fix. None of
them announce themselves, and a working installation looks the same either way,
which is why the last rule is about proving it rather than assuming it.

The rules below close all four. They apply to any provider. Under each rule,
the mechanism is named, because the mechanism is what tells you whether the rule
still holds on your release.

## What was verified, and against what

Every claim here was checked against **Chatwoot 4.17.1**, reading the source at
that tag. Version numbers, file paths and behaviours are stated with the release
they were read in.

Chatwoot moves quickly, and none of these behaviours are part of a documented
contract. Re-check anything load-bearing against your own release before you
rely on it. Where a claim could not be verified, it is in
[the unverified list](references/verification.md#claims-that-were-not-verified)
rather than in the prose.

## Reference files

This file holds the rules, the decision tables and the trap list. Each reference
below covers one topic in full. Read this file first, then open only the
references the task needs.

| Reference | Open it when you are | Lines |
| --- | --- | --- |
| [providers](references/providers.md) | choosing where Postgres, storage, mail and TLS come from, or checking a stack you already have against what Chatwoot needs | 599 |
| [install](references/install.md) | building an installation, in the order that keeps it private until it is hardened | 584 |
| [widget-security](references/widget-security.md) | patching the widget SDK, pinning it, or deciding what to do about either CVE | 490 |
| [inboxes-and-identity](references/inboxes-and-identity.md) | creating a website inbox, restricting who may embed it, or keeping one visitor one contact across several sites | 530 |
| [email](references/email.md) | deciding what address mail comes from, or finding out why replies go nowhere | 306 |
| [hardening](references/hardening.md) | closing the installation to everyone but its operators, or adapting the single-operator model to a team | 481 |
| [upgrades](references/upgrades.md) | moving to a new release, or recovering from one | 440 |
| [verification](references/verification.md) | about to claim the installation is safe | 274 |

`tools/` beside them holds what is worth having exactly rather than retyped: the
SDK patch and its build script, the Rails console scripts, the compose and proxy
templates, an outside-in checker and a probe that asks
[the provider questions](#questions-to-ask-of-any-stack) of a candidate stack.

Read [verification](references/verification.md) before you tell anyone the
installation is safe. A green dashboard shows what it was configured to show,
and the settings that matter are not on it.

## The eleven rules

**1. Pin an exact image digest.**
The `latest-ce` tag is repointed on every push to master, and migrations never
run on their own. A `docker pull` therefore leaves new code on an old schema,
with no error at pull time. Pin a specific `-ce` release by digest, and treat
changing that line as the upgrade it is.

**2. Finish onboarding before the hostname resolves.**
`Installation::OnboardingController#create` needs no authentication and builds a
user with `super_admin: true, confirmed: true`. Its only gate is a Redis key set
during seeding, and that key re-arms on any restore into an empty database. Do
the first boot on loopback, reach it through an SSH tunnel, and publish DNS
afterwards.

**3. Read the flags literally.**
`ENABLE_ACCOUNT_SIGNUP` is compared with `.to_s != 'false'`, so `off`, `0` and
`f` all leave signup enabled. `api_only` returns a live session with no email
confirmation, which is worse than `true`. `CREATE_NEW_ACCOUNT_FROM_DASHBOARD`
gates nothing on the server: it is one condition in a Vue template. After
seeding, the database row wins over the environment, so assert these in the
database.

**4. Keep the admin console off the public internet.**
`SuperAdmin::Devise::SessionsController#create` has no second-factor branch, so
it is a password away from everything while `/app/login` is not. Return 404 at
the proxy for the admin, monitoring and installation paths, and reach them
through the same tunnel you used for onboarding.

**5. Serve your own widget SDK, and do not fork the image.**
The shipped `sdk.js` accepts `postMessage` from any window and takes the popout
host out of the message, which hands the visitor's conversation cookie to
whoever sent it. The file is a single self-contained bundle at a stable path, so
one patched copy served by your proxy fixes it, on a stock server image.

**6. Give every widget inbox its allowed domains and mandatory HMAC.**
Leaving `allowed_domains` blank removes the framing restriction rather than
defaulting closed, so any site may embed the widget. Mandatory HMAC is what
stops a visitor claiming to be another visitor.

**7. Let identity come from your application, never from a cookie.**
Widening the widget cookie with `baseDomain` shares a live session across every
subdomain that setting covers. Identity continuity comes from signing an
identifier your application owns. Never use an email address as that
identifier: contact merging silently drops the attribute.

**8. Decide the email compromise before you design around it.**
A widget inbox has no From address of its own. Transcript mail comes from one
account-wide address, and operator mail from one global address. The per-inbox
column that looks like the answer can be read but not written. Receiving mail
is a separate provider question from sending it.

**9. Assign with a rule, not with round robin.**
Built-in auto assignment draws only from agents the presence tracker reports as
online, so a queue answered by one person goes unassigned for exactly the hours
nobody is watching. An automation rule on `conversation_created` carries no such
condition.

**10. Rehearse every upgrade against a copy of the data.**
There is no downgrade path. Migrations are one way, and the only recovery is a
database restore, so the rehearsal is what tells you whether the restore will be
needed. Read the release notes of every version you skip.

**11. Verify from outside and from the database.**
Outside-in checks prove what an attacker sees. The database audit proves the
settings that no page displays. Neither substitutes for the other, and the
dashboard substitutes for neither.

## Build order

Each step limits the next, and several are expensive to add later.

1. **Answer the provider questions.** What supplies Postgres, object storage,
   outbound mail and TLS decides the rest of the file layout.
2. **Reserve the address, and hold back DNS.** The hostname must not resolve
   until step 9.
3. **Prepare the host.** Docker, swap, and a firewall that opens SSH to you and
   the web ports to your edge.
4. **Prepare the database.** An application role, a database, the five
   extensions created by a privileged role, and ownership or grants.
5. **Prepare storage.** A private bucket and a key scoped to it.
6. **Write the environment.** Generated secrets first. Record which of them
   cannot be regenerated.
7. **Boot privately and migrate.** Loopback only, with a raised statement
   timeout passed to the prepare command alone.
8. **Onboard through a tunnel, then turn on the second factor.** Account
   settings follow.
9. **Build and serve the patched SDK**, and publish DNS once the proxy is
   returning 404 for the private paths.
10. **Create the first inbox** with its allowed domains, mandatory HMAC and an
    assignment rule.
11. **Verify**, outside-in and in the database, then record the release you are
    on so the next upgrade has a starting point.

Steps 2 and 9 are one decision split in two. Everything between them happens on
a machine the internet cannot reach by name.

## Choosing your providers

Most of this skill is Chatwoot behaviour, which no provider changes. A few
things depend on what your database, object store, mail provider and edge
actually do. Check those before you carry a decision from one stack to another.

### What each component must supply

| Component | It must | Or you get |
| --- | --- | --- |
| Postgres | be 14 or later, and offer `pg_stat_statements`, `pg_trgm`, `pgcrypto`, `plpgsql` and `vector` | a schema load that fails partway |
| Postgres | let a privileged role create those extensions and hand ownership to the application role, or grant it equivalent rights | migrations that cannot create tables |
| Postgres | allow a long statement for the duration of a migration | a migration killed mid-way |
| Object storage | accept S3 writes and reads from the application, with the bucket addressing style you configure | uploads that fail against a bucket that exists |
| Mail | verify the domain you send from | mail refused at submission |
| Mail | receive, if you want replies to become messages | transcripts that no one can reply to |
| Edge | set a client address header the client cannot set itself | rate limits a client picks its own bucket for |
| Edge | agree with the origin on who terminates TLS | a redirect loop, or a certificate the edge rejects |
| Host | run Docker, and have swap, with room for a migration's memory peak | an out-of-memory kill during asset work or a migration |
| Host | keep its address across a rebuild | a DNS change and a wait every time you rebuild |

### Questions to ask of any stack

Answer these before you install anything. `tools/probe-stack.sh` asks them and
prints `NOT MEASURED` plus the manual method for whatever it cannot reach.

1. **Is the database recent enough, and are the five extensions available?**
   The version floor bites during the first schema load, so a cluster that
   connects cleanly can still refuse to be installed into.
2. **What port does the database listen on?** Several managed providers do not
   use 5432. The container entrypoint probes the port you configure and waits
   silently on the wrong one.
3. **Who may create those extensions, and can ownership be handed over?**
   Availability and permission are separate questions, and a managed cluster
   usually answers yes to the first and no to the second for your application
   role.
4. **What is `statement_timeout`, and where is it set?** A provider default in
   the low tens of seconds is enough to kill a migration and not enough to
   notice in normal use.
5. **Does the object store accept what the application sends,** rather than only
   what a CLI sends? Some stores pass a command-line upload and reject the
   library's.
6. **Can the mail provider receive?** Sending and receiving are separate
   products, and Chatwoot needs an adapter for whichever receives.
7. **Which header carries the client address, and can a client send it?** Read
   the origin log for a request you sent with a forged header.
8. **Does the address outlive the machine?** This decides whether a rebuild is a
   ten-minute operation or a DNS change and a propagation wait.

Each answer is a fact about your stack on the day you measured it. Providers
change defaults, so measure again after any migration between them.

### Two topologies

**Topology A: managed services.** Postgres and object storage are managed, an
edge proxy terminates TLS for visitors, and the host runs Rails, Sidekiq, Redis
and a proxy. The host then holds no state that matters, and a rebuild is
routine. This is the shape that was built and measured. See
[providers](references/providers.md#topology-a-managed-services).

**Topology B: one box.** Postgres, Redis and file storage live on the host, and
the proxy answers visitors directly. Fewer moving parts and fewer bills, and you
take on backups, recovery and the database upgrade yourself. The requirements
are stated and the templates are written, and this topology was
**not verified**.
See [providers](references/providers.md#topology-b-one-box).

Known-bad combinations, with the open issues behind them, are in
[providers](references/providers.md#known-bad-combinations). Check that list
before choosing a component on familiarity.

### What no provider changes

Every Chatwoot behaviour in this skill: the onboarding endpoint, the flags and
how they are parsed, the admin console's missing second factor, the widget SDK
and its patch, the inbox model, allowed domains, HMAC identity, the email
identity limits, automation rules, the branding job, and every assertion in the
database audit. These are properties of the release you run, so they change with
the release and not with the host.

## What to decide for your own installation

This skill gives you a method and a shape. Four decisions are yours.

**How many people answer conversations.** The scripts and the audit encode a
single operator, because that is what was built. A team changes the audit's
expected counts, the assignment rule and the invitation policy. See
[hardening](references/hardening.md#the-single-operator-model) for what to
change, and note that invitations cannot be disabled by configuration at all.

**What the widget is allowed to cost you.** A widget accepts anonymous visitors
by definition, so spam and storage growth are the price of having one. The
controls are allowed domains, the pre-chat form, the upload cap and the rate
limits. Note that `tools/rails/add-website.rb` leaves the pre-chat form off,
trading that control for identity continuity, so out of the box you have three
of the four. Set them against your own tolerance.

**Whether message previews may cross someone else's servers.** Mobile push goes
through Chatwoot's relay unless you build and ship your own mobile app. For most
operators the relay is the right trade. It is still a privacy decision, so make
it deliberately rather than by leaving a default alone.

**What to do about the second CVE.** The article-viewer XSS lives inside the
application bundle, not the standalone SDK, so serving your own file does not
touch it. Fixing it means building an image. See
[widget-security](references/widget-security.md#the-second-cve) and decide in
writing.

## Decision tables

### One account or many

| You want | Do this | Why |
| --- | --- | --- |
| Several websites, one operator | One account, one inbox per trust boundary | Realtime events are filtered by account, so a second account notifies you of nothing while you are looking at the first |
| Separate billing or separate staff per brand | Separate installations | Account separation inside one installation does not separate operator mail, branding or the super admin |
| A staging copy | A separate installation on a copy of the data | Sharing an account between real and test traffic mixes contacts |

### How many inboxes a website needs

| Surface | Inbox | Note |
| --- | --- | --- |
| The website and its app, one visitor identity | One website inbox, all origins in `allowed_domains` | One inbox is what keeps one visitor one contact across those origins |
| A second site with its own visitors | Its own website inbox | A trust boundary is the unit, not a domain name |
| Replies by email | An email-channel inbox alongside | Only an email channel gets a per-inbox From address |

### Which secrets you cannot recreate

| Secret | Losing it costs |
| --- | --- |
| `SECRET_KEY_BASE` | Every session and every signed value in the database |
| The three `ACTIVE_RECORD_ENCRYPTION_*` keys | Every stored second-factor secret, unreadable |
| An inbox HMAC token | Nothing permanent: rotate it, then redeploy every signer at once |
| The storage key | Nothing permanent: issue a new one |
| The database password | Nothing permanent: reset it at the provider |

Back up the first two somewhere the installation does not reach. A restore of
the database alone, without them, is not a restore.

Everything in the lower three rows is replaceable, in one order. Issue the new
credential, put it everywhere that uses it, confirm it works, and revoke the old
one last. Revoking first is an outage you caused, and for an inbox HMAC token it
is an outage in someone else's deployment.

## The trap table

Fifteen behaviours that cost time to find. Each line links to the reference that
explains it.

| # | Trap | Where |
| --- | --- | --- |
| 1 | The onboarding endpoint re-arms on an empty database | [hardening](references/hardening.md#the-onboarding-window) |
| 2 | `ENABLE_ACCOUNT_SIGNUP` values `off`, `0` and `f` all mean enabled | [hardening](references/hardening.md#flags-that-are-not-booleans) |
| 3 | `api_only` is more dangerous than `true` | [hardening](references/hardening.md#flags-that-are-not-booleans) |
| 4 | `CREATE_NEW_ACCOUNT_FROM_DASHBOARD` gates nothing on the server | [hardening](references/hardening.md#flags-that-are-not-booleans) |
| 5 | A moving tag leaves new code on an old schema | [upgrades](references/upgrades.md#pinning-a-release) |
| 6 | A managed database on a non-default port hangs the readiness probe | [providers](references/providers.md#the-port) |
| 7 | A low `statement_timeout` kills migrations | [upgrades](references/upgrades.md#the-statement-timeout) |
| 8 | Blank `allowed_domains` lets any site embed the widget | [inboxes-and-identity](references/inboxes-and-identity.md#allowed-domains) |
| 9 | Setting `baseDomain` widens the session cookie | [inboxes-and-identity](references/inboxes-and-identity.md#the-cookie-and-its-scope) |
| 10 | Patching `sdk.js` without its compressed variants serves the patch to nobody | [widget-security](references/widget-security.md#the-compressed-variant-trap) |
| 11 | A pinned SDK degrades silently, because nothing checks its version | [widget-security](references/widget-security.md#detecting-drift) |
| 12 | A send-only mail provider cannot parse replies | [email](references/email.md#receiving-is-a-second-provider) |
| 13 | Realtime notifications are dropped by account, so multi-account notifies you of nothing | [inboxes-and-identity](references/inboxes-and-identity.md#one-account) |
| 14 | `conversation_unread_counts` ships off | [install](references/install.md#account-settings) |
| 15 | Installation branding is not yours to change, and the job that enforces it is stripped from the CE image | [hardening](references/hardening.md#branding) |

## Pre-launch checklist

Reachability:

- [ ] The public address serves the release you pinned.
- [ ] Admin, monitoring and installation paths return 404 from outside.
- [ ] Account creation over the API is refused on both API versions.
- [ ] The realtime endpoint accepts a websocket upgrade.

Hardening:

- [ ] Signup is disabled in the database, not only in the environment.
- [ ] The onboarding key is gone.
- [ ] No platform applications exist.
- [ ] Every operator has a second factor, and the encryption keys are set.
- [ ] No API-channel inbox and no help-centre portal exist.

Widget:

- [ ] The served `sdk.js` matches the patched build you made for this release.
- [ ] Embedding pages pin its integrity hash.
- [ ] A forged `postMessage` from another origin does nothing.
- [ ] Every widget inbox restricts framing and requires signed identities.
- [ ] The conversation cookie carries no `Domain` attribute.

Mail and storage:

- [ ] A password reset arrives, and passes SPF, DKIM and DMARC at the receiver.
- [ ] An attachment uploads, lands in the bucket, and downloads again.

Upgrade readiness:

- [ ] The pinned digest and the release notes are recorded.
- [ ] The secrets you cannot recreate are backed up off the installation.
- [ ] A restore has been rehearsed, not assumed.

## Reviewing an existing installation

Ask these in order. Each answer changes what the next one means.

1. **What does `/installation/onboarding` return from outside?** Anything but
   404 ends the review: the installation can be taken over, and nothing further
   matters until that is fixed.
2. **Is signup disabled in the database?** The environment variable is not the
   answer, and the three values that look disabled are not.
3. **What tag is running, and is it pinned by digest?** A moving tag means the
   schema and the code may already disagree.
4. **Where does `sdk.js` come from?** If it comes from the image, the widget
   accepts messages from any window on the page.
5. **Which inboxes have blank allowed domains or optional HMAC?** Each one is a
   site that can embed the widget or a visitor who can claim another identity.
6. **What address does transcript mail come from, and can anyone reply to it?**
7. **Who can reach the admin console, and does anything there need a second
   factor?**
8. **What happens on restore?** Ask where `SECRET_KEY_BASE` and the encryption
   keys are kept. If the answer is only the server, the backup is incomplete.
