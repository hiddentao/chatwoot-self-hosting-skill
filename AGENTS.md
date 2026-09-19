# Self-hosted Chatwoot

Rules for deploying, hardening and operating a self-hosted Chatwoot
installation. They were checked against Chatwoot 4.17.1 by reading the source at
that tag, and they apply on any provider.

This file is for agents without Agent Skills support. If your tool supports
skills, install the `chatwoot-self-hosting/` directory instead. It has the full
detail in eight reference files, and the agent reads each one only when a task
needs it.

## The rules

**1. Pin an exact image digest.** A moving tag is repointed on every push to
master, and migrations never run on their own, so a pull leaves new code on an
old schema with no error.

**2. Finish onboarding before the hostname resolves.** The onboarding endpoint
needs no authentication and builds a confirmed super admin. Its only gate is a
Redis key set during seeding, and that key re-arms on any restore into an empty
database. First boot happens on loopback, through an SSH tunnel.

**3. Read the flags literally.** `ENABLE_ACCOUNT_SIGNUP` is compared against the
string `false`, so `off`, `0` and `f` all leave signup on. `api_only` returns a
live session with no email confirmation. After seeding the database row wins
over the environment, so assert these in the database.

**4. Keep the admin console off the public internet.** The super admin login has
no second-factor branch. Return 404 at the proxy for the admin, monitoring and
installation paths, and reach them through a tunnel.

**5. Serve your own widget SDK, and do not fork the image.** The shipped file
accepts `postMessage` from any window and takes the popout host out of the
message, which hands the visitor's conversation cookie to whoever sent it. One
patched copy served by your proxy fixes it on a stock server image.

**6. Give every widget inbox its allowed domains and mandatory HMAC.** A blank
allowed-domains list removes the framing restriction rather than defaulting
closed. Mandatory HMAC is what stops a visitor claiming to be another visitor.

**7. Let identity come from your application, never from a cookie.** Widening
the widget cookie with `baseDomain` shares a live session across every subdomain
it covers. Sign an identifier your application owns, and never use an email
address as that identifier.

**8. Decide the email compromise before you design around it.** A widget inbox
has no From address of its own. Transcript mail comes from one account-wide
address and operator mail from one global address. Receiving mail is a separate
provider question from sending it.

**9. Assign with a rule, not with round robin.** Built-in auto assignment draws
only from agents currently reported online, so a small queue goes unassigned for
exactly the hours nobody is watching.

**10. Rehearse every upgrade against a copy of the data.** There is no
downgrade. The only recovery is a database restore, so the rehearsal is what
tells you whether you will need one.

**11. Verify from outside and from the database.** Outside-in checks prove what
an attacker sees. The database audit proves the settings no page displays. The
dashboard proves neither.

## Before you call an installation safe

Check what an outsider sees and what the database holds, and say which release
you checked. A green dashboard shows what it was configured to show, and the
settings that matter are not on it. Back up `SECRET_KEY_BASE` and the three
Active Record encryption keys somewhere the installation does not reach: a
restore without them is not a restore.

## What to decide for your own installation

How many people answer conversations, what a public widget is allowed to cost
you in spam and storage, whether message previews may cross a third party's push
relay, and what to do about the article-viewer CVE that serving your own SDK
does not touch. None of these have a default worth inheriting.

## Editing this skill itself

This file is the rules, for your installation. If you are changing the skill
rather than using it, `CONTRIBUTING.md` in the skill's own repository has the
conventions: how prose is written, how a claim records the release it was
verified against, and the checks a change goes through.
