# Upgrades, and getting back

Moving to a new release without learning in production that the schema no longer
matches the code, and what is left to you when something goes wrong anyway.

Every claim here was checked against Chatwoot 4.17.1, reading the source at that
tag. Upstream ships around twenty releases a year, so treat the mechanisms as
things to re-check rather than constants.

#### Pinning a release

One workflow publishes every CE image.
`.github/workflows/publish_foss_docker.yml` triggers on a push to `develop` or
`master`, on a tag matching `v*`, and on manual dispatch. Its tag step reads:

```
if github.ref_name is "master"  ->  chatwoot/chatwoot:latest-ce
otherwise                       ->  chatwoot/chatwoot:<sanitized ref>-ce
```

So a merge to master republishes `latest-ce`, a push to `develop` publishes
`develop-ce`, and a release tag publishes `vX.Y.Z-ce`. The same job produces
both kinds of tag, which is the point worth holding on to: a release tag is not
safer by accident, it is safer because its name is derived from a ref that
cannot move.

The other half of the trap is that migrations never run automatically. Nothing
in the container's start-up applies a pending migration, by design.

Put those two together. A `docker pull` on a moving tag fetches new code, the
containers restart cleanly, and the schema underneath is the old one. There is
no error at pull time, because pulling is not the operation that would notice.
What you get instead is a working dashboard and a subset of pages that raise on
a missing column, found by whoever opens one first. Upstream's own Helm
documentation recommends immutable tags, which is the same advice arrived at
from the other direction.

So pin a digest, and treat editing that line as the upgrade it is. Pin a `-ce`
tag specifically: the same workflow strips the `enterprise/` tree before
building, so a `-ce` image carries no separately licensed enterprise code, and
the plain tags do.

##### Finding a digest

`imagetools` is the right tool to ask, and the publish workflow itself uses it:

```
docker buildx imagetools inspect chatwoot/chatwoot:v4.17.1-ce | grep -m1 Digest
```

Then the compose file carries tag and digest together, so the file is readable
by a person and unambiguous to the runtime:

```
image: chatwoot/chatwoot:v4.17.1-ce@sha256:<64 hex characters>
```

Pin it in one place only. Every script that needs to know which release is
running should read it from that file rather than hold its own copy, or the two
will disagree exactly once, during an upgrade, which is the worst moment for it.

#### The recurring cost

An upgrade is not a pull. Budget it as a scheduled piece of work, at a quiet
hour, with a way back.

Migrations are the bulk of it. Seventy-four were added during 2026, counted at
the 4.17.1 tag in September of that year, and none of them runs on its own. You
run `db:chatwoot_prepare`, you wait, and until it finishes the application is
serving an old schema or nothing.

There is no documented rollback. Migrations are one way, and a restore of the
database is the only recovery upstream offers. That is what makes the rehearsal
below worth its time: it tells you whether you are about to need the restore.

Read the release notes of every version you skip, one by one. Skipping four
releases means reading four sets of notes, because the breaking change is in the
one you did not look at. There is precedent for a forced intermediate stop:
upstream issue #12088 reports that v3.x to v4.2 and later fails, and that a stop
at v4.1 is mandatory. It was closed as not planned, so the requirement stands
rather than being fixed.

Read the shape of that issue carefully. The failure happens **only on
installations with real users**. An upgrade rehearsed against an empty database
passes, and the same upgrade against yours does not. That is the argument for
rehearsing against a copy of your own data rather than against a clean install.

#### Rehearsing against a copy of the data

The rehearsal runs the new release against a copy of your database, on a stack
that cannot reach anyone.

Set the release you are rehearsing once, in the shell you will run all of this
from. `tools/templates/compose.staging.yaml` reads it and refuses to start
without it, so every command below assumes it:

```
export STAGING_IMAGE=chatwoot/chatwoot:v4.18.0-ce@sha256:<digest>
```

Then, in order:

1. Build the patched widget SDK for the new release, and stop if its hash
   changed until every embedding page accepts both hashes. See
   [the SDK step](#the-sdk-step-of-an-upgrade).
2. Copy the data. On a provider that can fork a cluster to a point in time, fork
   production as it was a couple of minutes ago. Without one, see
   [rehearsing without a fork](#rehearsing-without-a-fork).
3. Add the host to the copy's allowed sources. The copy is a new cluster with a
   new hostname and its own list, and that list starts empty, so this is the
   step whose absence looks exactly like a wrong port. The empty-list trap
   applies here too: a copy with no rules at all already accepts everything, so
   adding a first rule is a change rather than an addition. The
   [restore section](#a-restored-database-is-a-new-database) has the same trap
   under worse conditions.
4. Bring up a second stack against the copy, under its own compose project name,
   with the new image.
5. Run the migrations there, with the raised statement timeout.
6. Assert, then look at it yourself.
7. Confirm, then upgrade production: pin the new image, copy the changed files
   across without touching the host's `.env`, pull, stop Rails and Sidekiq, run
   the migrations with the raised timeout, start everything again, verify from
   outside. Print a restore point first, a UTC timestamp taken before the
   migrations start, so you know what to ask the provider for.
8. Delete the copy, the second stack and `.env.staging`, on the way out and on
   failure alike.

##### A throwaway stack that cannot reach anyone

The second stack uses production's environment, because an environment that
differs from production tests a different installation. The edits that make it
harmless are worth reading for the pattern rather than the values:

```
# The staging environment is production's, pointed at the copy, with mail and
# push delivery made impossible rather than merely switched off.
sed -e 's#^POSTGRES_HOST=.*#POSTGRES_HOST=<the copy>#' \
    -e 's#^SMTP_ADDRESS=.*#SMTP_ADDRESS=127.0.0.1#' \
    -e 's#^SMTP_PORT=.*#SMTP_PORT=1#' \
    -e 's#^ENABLE_PUSH_RELAY_SERVER=.*#ENABLE_PUSH_RELAY_SERVER=false#' \
    .env > .env.staging
```

The mail edit points the SMTP client at a port where nothing listens. A stack
holding a copy of production's data holds production's contacts, and something
in a migration or a boot-time job will eventually try to write to one of them.
A flag that says "do not send" is one careless edit from sending. An address
that cannot connect fails whatever the code decides to do, and fails loudly in
the log rather than quietly in someone's inbox.

Two more properties of the stack matter as much as the environment.

It runs no background jobs. The staging compose file defines the web process and
Redis, and no Sidekiq service at all. Scheduled jobs are the other way a
rehearsal reaches the outside world, and the way to stop them is to not start
the process that runs them.

It is never public. Bind its port to loopback on a port production does not use,
`127.0.0.1:3001`, and reach it over the same SSH tunnel you use for the admin
console. The proxy knows nothing about it, so there is nothing to get wrong.

Two of the three are structural, which is the point: a missing service cannot be
started by accident, and a loopback port is not reachable from anywhere else.
The third is configuration, but of a kind that fails the safe way. An address
that cannot connect fails loudly in the log, where a flag saying do not send
fails silently and is one careless edit from sending.
`tools/templates/compose.staging.yaml` is that file, and it runs under its own
compose project name so it can never recreate a production container.

Delete `.env.staging` when you are done, every time, including after a failed
rehearsal. It is a verbatim copy of production's secrets, `SECRET_KEY_BASE`, the
three encryption keys, the database password and the mail credential, sitting
next to the real one under a name nothing else reads. Tearing down the
containers does not remove it:

```
docker compose -p chatwoot-staging -f compose.staging.yaml down -v
rm -f .env.staging
```

##### What to assert before believing it passed

"The container started" is not a pass. An entrypoint waiting on the wrong
database port also starts, and waits quietly.

```
# The migrations completed, with the raised timeout, and exited zero.
docker compose -p chatwoot-staging -f compose.staging.yaml \
  run --rm -e POSTGRES_STATEMENT_TIMEOUT=600s \
  rails bundle exec rails db:chatwoot_prepare

# The running app reports the version you are upgrading to, exactly.
curl -fsS http://127.0.0.1:3001/api | jq -r .version     # must equal 4.18.0

# The login page renders.
curl -fsS -o /dev/null http://127.0.0.1:3001/app/login
```

The version check is the one people leave out, and it catches a compose file
that still pins the old image. Compare against the tag without its leading `v`,
and fail the rehearsal on a mismatch rather than reading it. Then look at the
rehearsal yourself, through a tunnel, before you confirm anything:

```
ssh -L 3001:127.0.0.1:3001 operator@<host address>
```

Open the dashboard, open a conversation with real history in it, open the inbox
settings page. Three pages that read three different parts of the schema tell
you more than any amount of green output, because the failure mode of a partly
applied migration is a page that raises, and no check above loads a page.

#### Rehearsing without a fork

Topology B keeps Postgres on the host, so there is no provider to ask for a
point-in-time copy. The rehearsal still needs the same three things: a copy of
your data, a stack that cannot reach anyone, and a way to throw both away.

This procedure is derived from the requirements above and **was not tested**.
Topology B itself was **not verified** either, so treat what follows as a shape
to work from: [providers](providers.md#topology-b-one-box).

```
# 1. Copy the data into a second database on the same server.
pg_dump --format=custom --dbname=chatwoot --file=/var/tmp/chatwoot.dump

# 2. Create the copy, with the five extensions made by a privileged role
#    BEFORE the restore, and ownership handed to the application role.
createdb chatwoot_rehearsal
psql --dbname=chatwoot_rehearsal --file=db-init.sql     # as the superuser
pg_restore --dbname=chatwoot_rehearsal --no-owner /var/tmp/chatwoot.dump

# 3. Point the staging environment at it, with the same mail and push edits.
sed -e 's#^POSTGRES_DATABASE=.*#POSTGRES_DATABASE=chatwoot_rehearsal#' \
    -e 's#^SMTP_ADDRESS=.*#SMTP_ADDRESS=127.0.0.1#' \
    -e 's#^SMTP_PORT=.*#SMTP_PORT=1#' \
    -e 's#^ENABLE_PUSH_RELAY_SERVER=.*#ENABLE_PUSH_RELAY_SERVER=false#' \
    .env > .env.staging

# 4. Migrate, assert and look, exactly as above.
# 5. dropdb chatwoot_rehearsal, and delete the dump.
```

Four things are different from the managed case, and each can bite.

The dump and the restore run on the machine that is serving production. On a
database of any size that is real I/O and real time, competing with live
traffic. Do it at a quiet hour, and check free disk before you start: you need
room for the dump and for a second copy of the data at once.

The extensions are the first install's obstacle, met again. A restore issues
`CREATE EXTENSION`, and the application role is usually not allowed to, so
create all five as the privileged role before the restore.

The copy is production data: every message, every contact, every attachment
reference. It deserves a backup's file permissions and a backup's disposal, and
it should not outlive the rehearsal.

Object storage is shared unless you make it otherwise. The staging stack points
at the same bucket as production, so anything it writes lands in the real
bucket. Either point it at a throwaway bucket or accept that a rehearsal can add
objects, and write down which you chose.

#### The statement timeout

The default `statement_timeout` kills migrations. One managed provider defaults
to 14 seconds, which is generous for every query the application makes and far
too short for a migration that rewrites a large table. The failure is a
migration killed partway, in the middle of a run, which leaves the schema
somewhere between two releases.

Upstream knows. Its own Procfile runs the prepare step with
`POSTGRES_STATEMENT_TIMEOUT=600s`. The Docker upgrade documentation omits it,
which is how the trap survives.

Pass the raised value to the prepare command alone:

```
docker compose run --rm -e POSTGRES_STATEMENT_TIMEOUT=600s \
  rails bundle exec rails db:chatwoot_prepare
```

Never put it in `.env`. The low default is protecting the live application: it
stops one pathological query from holding a connection and a worker for ten
minutes under load. Raising it globally to make an upgrade work trades a problem
you have once for a problem you have continuously.
`tools/templates/env.template` leaves the variable out on purpose and says so in
a comment, because an absent line invites the question and a commented-out line
invites uncommenting.

Measure your own default rather than assuming this one, the way you measured the
port ([providers](providers.md#the-port)). A provider default in the low tens of
seconds is invisible in normal use and fatal in a migration, so nothing about
the running installation will tell you it is there.

A raised timeout buys time. It does not make a migration safe to interrupt, and
it does not give you a way back. That is still the restore.

#### The SDK step of an upgrade

The patched widget SDK is built against one release. A new release means a new
build, and the build is part of the upgrade rather than a follow-up.

```
tools/patch-sdk.sh v4.18.0 chatwoot/chatwoot:v4.18.0-ce@sha256:<digest> ./sdk
```

It does four things, in this order:

It extracts the `sdk.js` the new image ships and compares its sha256 with the
hash recorded for the previous release. Unchanged means the widget contract you
patched against is the one you are patching again. Changed means read the
difference before you go further: there is no version negotiation anywhere in
the SDK, so a new configuration key or event is exactly the kind of change that
degrades silently rather than failing. See
[widget-security](widget-security.md#detecting-drift).

It builds the SDK from the release's source with no changes, and stops unless
the result matches the shipped file byte for byte. A build that cannot reproduce
upstream tells you nothing about what the patched build contains.

It applies the patch and runs the guard spec. If the patch no longer applies,
the script stops, and rebasing it against the new source is the work. Do that
before production changes, not after.

It prints the new Subresource Integrity hash.

Then block the rollout on that hash. Every embedding page pins the old one, so
serving the new file first means browsers refuse to run it and the widget
vanishes from every site at once. An `integrity` attribute takes several hashes
separated by spaces and runs the file if any of them matches, which is what
makes a safe order possible:

1. Add the new hash beside the old one everywhere the integrity value is
   configured, and deploy those pages.
2. Serve the new `sdk.js` on the installation.
3. Remove the old hash everywhere, and deploy again.

Three deploys, and the widget works throughout. Doing it in two breaks every
site for the length of the gap. The full procedure is in
[widget-security](widget-security.md#rolling-out-a-new-hash).

Once production serves the new file, send a forged `chatwoot-widget:` message
from another origin and confirm nothing happens. The guard you depend on lives
in the file you just replaced, and a rebuilt SDK is the one change that can
remove it silently: [verification](verification.md#the-forged-message-test).

#### Restore and rebuild

A database restore brings back rows. It brings back conversations, contacts,
inboxes with their website and HMAC tokens, account settings and the
installation config rows that decide whether signup is open. It does not bring
back anything that lives in the environment, and two of those cannot be
recreated at all.

`SECRET_KEY_BASE` signs every session and every signed value in the database.
Restore rows under a new one and the signed values no longer verify.

The three `ACTIVE_RECORD_ENCRYPTION_*` keys are what make stored second-factor
secrets readable. Restore rows without them and every operator with a second
factor is locked out, permanently: there is no recovery path, because the
database holds only ciphertext.

Keep both somewhere the installation does not reach. A copy on the host is not a
backup of the host.

The rest can be reissued. An inbox HMAC token can be rotated, as long as every
signer is redeployed with the new one at the same time. A storage key can be
replaced at the provider. A database password can be reset. None of those costs
you history. Reissue in that order though: put the new credential everywhere
that uses it, confirm it works, and revoke the old one last. Revoking first
turns a rotation into an outage you caused.

##### A restored database is a new database

A managed provider restores into a new cluster rather than rewinding the one you
have. That is the safe design, and it is also the part that catches people: the
new cluster has its own hostname and its own access list, and that list starts
empty. So a restore is five steps, not one.

```
# 1. Restore the backup into a new cluster.
# 2. Recreate the application role and database on it, and run db-init.sql.
# 3. Add the host to the new cluster's allowed sources. It is not there yet.
# 4. Point POSTGRES_HOST at the new hostname in the server environment.
# 5. Recreate the containers so they read it, then run the audit in full.
```

Step 3 is the one that gets skipped, and skipping it fails with the symptom you
have already learned to read as a wrong port: an entrypoint that waits quietly
and reports nothing useful. Under incident conditions that is an expensive wrong
turn. A rehearsal copy is a new cluster in exactly the same way, with its own
hostname and its own empty list, so
[the rehearsal](#rehearsing-against-a-copy-of-the-data) meets this first in
calmer circumstances. That is one of the better arguments for rehearsing.

##### A restore into an empty database reopens onboarding

This is the trap that turns a recovery into an incident. If a restore leaves the
database empty, for any reason, `db:chatwoot_prepare` seeds it again, and
seeding re-arms the unauthenticated onboarding endpoint. The installation is now
in the same state it was in on the day it was built, except that this time the
hostname resolves.

The proxy's 404 rule is what stands between that and a stranger with a confirmed
super admin account, which is why that rule is permanent rather than a first-day
measure. Complete onboarding again over the tunnel, straight away, before
anything else. See [hardening](hardening.md#the-onboarding-window).

Then re-run the database audit in full. A reseeded installation has default
settings, so the signup row, the unread-count feature and anything else set
after the first onboarding are all back to their defaults and none of it shows
on the dashboard.

##### Rebuilding the host

In topology A the host holds nothing that matters. Postgres and object storage
are elsewhere, and Redis holds queues and caches. A rebuild is routine, and the
only thing to be careful about is the file that is not in the repository:

1. Save the host's `.env` somewhere else, if you can still reach it. This is
   what decides whether the rebuild is cheap or expensive.
2. Destroy and provision again.
3. Put the saved `.env` back before anything generates a new one, with mode 600.
4. Start the stack, and run the outside-in checks and the database audit.

Without the saved file you are generating new secrets, which means new sessions
for everyone and a second factor that every operator has to enrol again. The
database survives either way.

Keep the address across the rebuild. An address that belongs to the machine
makes every rebuild a DNS change plus a propagation wait, on the day you are
least able to wait; an address that belongs to the account and is attached to
the machine makes the rebuild invisible from outside. That is one of the
provider questions, worth answering before you need it:
[providers](providers.md#topology-a-managed-services).

Rehearse the restore as well. A backup that has never been restored is a
hypothesis, which is why the pre-launch checklist under
[The eleven rules](../SKILL.md#the-eleven-rules) asks for the rehearsal.
