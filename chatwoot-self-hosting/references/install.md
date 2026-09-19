# Installing, in the order that keeps it private

The eleven steps of [the build order](../SKILL.md#build-order) in operational
detail: what each one produces, what it forbids until it is done, and the
commands that do it. Every Chatwoot behaviour here was checked against
**Chatwoot 4.17.1**. The steps are provider neutral. Where one differs between
[topology A](providers.md#topology-a-managed-services) and
[topology B](providers.md#topology-b-one-box), both are given, and topology B is
labelled unverified wherever it appears, because it is.

#### The private window

Steps 2 and 9 of the build order are one decision split in two. The hostname
must not resolve until the installation is hardened, and everything in between
happens on a machine the internet cannot reach by name.

One endpoint is the reason. `Installation::OnboardingController#create` needs no
authentication and builds a user with `super_admin: true, confirmed: true`. Its
only gate is a Redis key set during seeding. Whoever reaches it first owns the
installation, and that key re-arms on any restore into an empty database. See
[hardening](hardening.md#the-onboarding-window).

Five things must be true before you publish the record. Each is produced by a
step below, and none can be added afterwards without a period where the
installation is both public and open:

- [ ] Onboarding is complete, and its Redis key is gone.
- [ ] The operator has a second factor.
- [ ] Signup is `false` in the database, not only in the environment.
- [ ] The proxy returns 404 for the admin, monitoring and installation paths.
- [ ] The `sdk.js` being served is your patched build.

#### Preparing the host

##### Docker and swap

Install Docker and the compose plugin from the distribution's own packages;
nothing here needs a recent one. Add swap before the first boot. Topology A ran
two gigabytes alongside eight of RAM:

```
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

The fstab line is what makes it survive a reboot. Without swap, the memory peak
during migrations and asset work is an out-of-memory kill, which reaches you as
a container that died with nothing useful in its log. If your provider runs
cloud-init, put the package install and the swap block in the instance's user
data, so a rebuilt host comes back with both.

One thing to know before you gate anything on it: `cloud-init status --wait`
exits non-zero when first boot finished with recoverable warnings, which is
common and harmless. A script that treats that exit code as failure stops on a
host that is perfectly fine. Wait for it, ignore the code, and assert what you
actually need instead, which is that Docker and Compose respond.

```
cloud-init status --wait || true
docker compose version        # this is the real check
```

##### The firewall and the loopback binding

Inbound: SSH from the address or range you decided on, 80 and 443 for whatever
reaches the origin, and nothing else. Outbound: everything. The full shape, and
the reasoning behind the SSH row, is in
[providers](providers.md#the-firewall).

Publish Rails on `127.0.0.1:3000`, never on `0.0.0.0`. The proxy reaches it over
the compose network and nothing on the public interface can. That binding, more
than the firewall, is what lets the whole application run before any name points
at the host. When SSH stops answering, your own address has usually moved:
repoint that one rule before you suspect the host.

#### Preparing the database

Create an application role and a database for it, then run the preparation
script as a privileged role, connected to that database:

```
CONN='host=<host> port=<port> dbname=chatwoot user=<admin> sslmode=require'
psql -v approle=chatwoot -v ON_ERROR_STOP=1 -f db-init.sql "$CONN"
```

Run it from inside the network that reaches the database. A managed cluster on a
private network is not reachable from your laptop, so run it from the host you
just prepared. If that host has no `psql`, a throwaway container has one:

```
printf '%s' "$ADMIN_PASSWORD" | ssh <host> "PGPASSWORD=\$(cat) \
  docker run --rm -e PGPASSWORD -v /root/db-init.sql:/db-init.sql:ro \
  postgres:17-alpine psql '$CONN' -v ON_ERROR_STOP=1 -f /db-init.sql"
```

The password travels on standard input. A password in a command line sits in
your shell history, and in the process table of the host while the command runs.

Read what the script prints. If the owner it reports is your application role,
migrations can create tables. If it is the admin role and the script printed its
grant notice, they can too, by the other path. If neither happened, stop here
and fix the permissions:
[providers](providers.md#ownership-or-the-grants-that-stand-in-for-it). In
topology B the same file runs unattended from the container's initdb directory
on an empty data directory, where the application role already owns everything.
Not verified.

Managed clusters usually keep a trusted-source list. Add the host to it now.
Watch for one trap: a cluster with no trusted sources at all accepts every
source, so adding a first rule locks out every other client of that cluster. Add
the rules for all of its clients in one change.

#### Preparing storage

Create a private bucket and a key scoped to it. Chatwoot serves attachments
through its own authenticated routes, so the bucket never needs to be public.

Probe the key before you write it into the environment:

```
B='--bucket <bucket> --key probe --endpoint-url <endpoint>'
aws s3api put-object    $B --body /tmp/probe
aws s3api get-object    $B /dev/null
aws s3api delete-object $B
```

`tools/probe-stack.sh` runs the same three. Passing is necessary and not
sufficient: some stores accept a CLI upload and reject the library's. The test
that counts is a real attachment through the dashboard, during verification.
Check your store against the two open issues in
[providers](providers.md#object-storage) first.

In topology B there is no bucket. Set `ACTIVE_STORAGE_SERVICE=local`, mount
`/app/storage` on both Rails and Sidekiq because both write to it, and add that
volume to your backups: it is the one piece of state the database cannot
recreate. Not verified.

#### Writing the environment

Copy the template to `.env` beside the compose file, with a mode nobody else can
read:

```
umask 077 && cp env.template .env
```

Fill it in three passes: the generated secrets, then the provider values you
measured, then the keys your providers issued.

##### Generating each secret

| Variable | Command |
| --- | --- |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `openssl rand -hex 32` |
| `REDIS_PASSWORD` | `openssl rand -hex 32` |

`SECRET_KEY_BASE` must be alphanumeric, which hex output is. Rails will generate
the three encryption keys itself once the image is pulled, printing them in YAML
form for you to copy across:

```
docker compose run --rm rails bundle exec rails db:encryption:init
```

Either route is fine; pick one. Then the values that are not generated:

| Variable | Value |
| --- | --- |
| `FRONTEND_URL` | the public URL exactly, scheme and host |
| `DOMAIN` | the bare hostname the proxy answers TLS on |
| `FORCE_SSL` | `false` in topology A, where TLS ends at the edge; `true` in topology B |
| `ENABLE_ACCOUNT_SIGNUP` | exactly `false`, and check the database later |
| `POSTGRES_HOST`, `POSTGRES_PORT` | the private host and the port you measured |
| `PGSSLMODE` | `require` for a managed cluster; absent in topology B |
| `MAILER_SENDER_EMAIL` | an address on the verified sending domain |
| `RACK_ATTACK_LIMIT` | `300`; upstream's default is 3000 |

`ENABLE_ACCOUNT_SIGNUP` is compared against the string `false`, so `off`, `0`
and `f` all leave signup on, and `api_only` is worse than `true`:
[hardening](hardening.md#flags-that-are-not-booleans). `FRONTEND_URL` has to
match the public URL character for character. `POSTGRES_STATEMENT_TIMEOUT` is
absent from the template on purpose:
[upgrades](upgrades.md#the-statement-timeout).

##### Checking for unfilled placeholders

Template placeholders are angle-bracketed. One grep finds every one you missed:

```
grep -E '^[A-Z_]+=.*<[^<>@]*>' .env      # must print nothing
```

The character class is the part that matters, because one filled value
legitimately contains angle brackets:

```
MAILER_SENDER_EMAIL=Chatwoot <no-reply@mail.example.com>
```

Excluding `@` stops the pattern matching across an address, so a correctly
filled sender does not report as unfilled, while `<generated>`, `<bucket>` and
`<your provider's port>` all still do. Excluding the brackets themselves stops
one placeholder matching from the opening bracket of one to the closing bracket
of another, several lines away.

Run it after every edit. It is the cheapest check here, and it catches a
failure that otherwise appears much later as a container that will not start.

##### The secrets you cannot regenerate

`SECRET_KEY_BASE` signs every session and every signed value in the database.
The three `ACTIVE_RECORD_ENCRYPTION_*` keys are what make stored second-factor
secrets readable. Losing any of the four is unrecoverable, and a database
restore without them is not a restore. Back all four up somewhere the
installation does not reach, before you go further. Everything else can be
reissued at its provider:
[the secret table](../SKILL.md#which-secrets-you-cannot-recreate).

#### Booting privately, and the migration

Redis first, because the prepare command needs it:

```
docker compose up -d redis
docker compose run --rm -e POSTGRES_STATEMENT_TIMEOUT=600s \
  rails bundle exec rails db:chatwoot_prepare
```

On an empty database this loads the schema and seeds the installation, and the
seed is what opens the onboarding page. On a database that already has a schema
it runs the pending migrations and nothing else, which is why the upgrade path
uses the same command.

The raised timeout goes here and nowhere near `.env`. The provider default
protects the live application from a runaway query, and a migration is the one
thing that legitimately runs for minutes:
[upgrades](upgrades.md#the-statement-timeout). A prepare command that hangs
with no output at all is almost always the entrypoint's readiness probe, which
means the host or the port: [providers](providers.md#the-port).

Then bring up the rest:

```
docker compose up -d --wait
docker compose ps
```

`--wait` returns once the healthchecks pass, so a failure here is a failure
rather than a race you find later. The installation is now running, reachable on
loopback, and unreachable by name.

#### Running the rails scripts

Everything in `tools/rails/` is a plain Ruby file that runs inside the Rails
container. No provider tooling, no gem to install, no console session left open:

```
docker compose exec -T -e SUPPORT_EMAIL="Support <no-reply@mail.example.com>" \
  rails bundle exec rails runner - < tools/rails/account-setup.rb
```

Three parts of that command each do a job:

- `-T` allocates no pseudo-terminal, which leaves standard input free for the
  file. Without it, compose takes the terminal and the redirect has nowhere to
  go.
- The bare `-` tells `rails runner` to read the program from standard input, so
  nothing is copied into the container and nothing is left behind in it. That is
  documented Rails behaviour rather than a trick: the runner command tests for
  the literal `-` and evaluates what it reads from standard input, confirmed in
  the Rails 7.2.3.1 source that Chatwoot 4.17.1 runs on. If you would rather not
  depend on it, copy the file in and give its path instead. The scripts do not
  care which way they arrive.
- Each `-e` puts one parameter into the script's environment. The scripts read
  their inputs with `ENV.fetch`, so a missing one fails loudly instead of
  writing a blank, and no value appears in a command line.

Over SSH from the operator machine it is the same command, with the file piped
through the connection:

```
ssh <host> "cd /opt/chatwoot && docker compose exec -T -e INBOX_NAME=Example \
  rails bundle exec rails runner -" < tools/rails/add-website.rb
```

| Script | Parameters | What it does |
| --- | --- | --- |
| `account-setup.rb` | `SUPPORT_EMAIL` | the two account-wide settings |
| `add-website.rb` | `INBOX_NAME`, `WEBSITE_URL`, `ALLOWED_DOMAINS`, `BUSINESS_NAME` | creates or updates one website inbox |
| `auto-assign.rb` | `INBOX_NAME` | the assignment rule, and anything already waiting |
| `rotate-hmac.rb` | `INBOX_NAME` | a fresh HMAC token, deliberately not printed |
| `audit.rb` | none | the database audit; exits non-zero on any broken rule |

All but one are safe to run again: they find an existing record and update it,
and the three that take an inbox match its name without case, so an inbox
renamed in the dashboard is updated rather than duplicated. `rotate-hmac.rb` is
the exception, because every run issues a different token.

Wire `audit.rb`'s exit code into a deploy script and let a broken rule fail the
deploy, rather than reading its output when you happen to remember.

#### Onboarding over a tunnel

Open a tunnel from the operator machine to the loopback port:

```
ssh -N -o ServerAliveInterval=20 -L 3000:127.0.0.1:3000 <user>@<host>
```

`-N` runs no remote command, and the keepalive stops an idle tunnel being
dropped while you are filling in a form.

Open `http://localhost:3000/installation/onboarding` and create the operator
user. After you submit, the application may redirect to `FRONTEND_URL`, which
does not resolve yet. That is expected. Open `http://localhost:3000/app/login`
yourself and sign in.

Keep the tunnel. It is also how you reach `/super_admin` afterwards, because the
proxy returns 404 for that path from outside and
`SuperAdmin::Devise::SessionsController#create` has no second-factor branch at
all. A password is the only thing between that console and everything in the
installation, which is why it never gets a public route:
[hardening](hardening.md#the-onboarding-window). Plan for the restore case too:
the onboarding key re-arms on any restore into an empty database, so a restore
is also a re-onboarding, over this same tunnel, immediately.

#### Turning on the second factor

In the dashboard: **Profile settings**, then **Two-factor authentication**.
Store the backup codes somewhere that is not this installation.

It works only when the three `ACTIVE_RECORD_ENCRYPTION_*` keys are set:
`Chatwoot.mfa_enabled?` is exactly `encryption_configured?`. If the toggle is
absent from the page, the keys are absent from `.env`.

Do this before DNS. Signup is off and nobody knows the hostname yet, so the
exposure is small, and small is not none.

#### Account settings

Two settings, both account-wide, both applied by one script:

```
docker compose exec -T -e SUPPORT_EMAIL="Support <no-reply@mail.example.com>" \
  rails bundle exec rails runner - < tools/rails/account-setup.rb
```

`conversation_unread_counts` ships off. With it off the sidebar shows no
per-inbox unread badge, so a queue you are not currently looking at gives no
sign that anything arrived in it. The script turns it on, and the database audit
checks it stayed on.

`support_email` is the From address on visitor transcript mail, and it is
account-wide. A widget inbox has no From address of its own: the per-inbox
column that looks like the answer is unreachable from the UI and the API, and
inert where it is read. So this one address covers every widget inbox in the
account, distinguished only by each inbox's `business_name`. See
[email](email.md#receiving-is-a-second-provider) for the whole compromise, and
for what an email-channel inbox changes about it.

The script stops unless exactly one account exists, which is the single-operator
model showing through: [hardening](hardening.md#the-single-operator-model) says
what a team changes.

#### The patched SDK

Build it before DNS, so the first public request already gets the patched file:

```
tools/patch-sdk.sh v4.17.1 chatwoot/chatwoot:v4.17.1-ce@sha256:<digest> ./sdk
```

The script's second step is a gate: it builds the SDK from the release's source
with no changes and stops unless the result matches the file the image ships,
byte for byte. A build that does not reproduce upstream tells you nothing about
what the patched build contains.

Serve the result at `/packs/js/sdk.js` from the proxy, on a route that runs
ahead of the one forwarding to Rails. The precompressed `.br` and `.gz` copies
inside the image never come into it, because the request never reaches Rails.
That is what makes this work on a stock server image, and it is also the trap
when the patch is applied the other way round:
[widget-security](widget-security.md#the-compressed-variant-trap).

The proxy must send `Access-Control-Allow-Origin: *` on that file, so embedding
pages can pin it with Subresource Integrity (SRI, the `integrity` attribute that
makes a browser refuse a script whose hash has changed). `patch-sdk.sh` prints
the string to pin, and changing it later takes three deploys in a fixed order:
[widget-security](widget-security.md#rolling-out-a-new-hash).

Record the upstream hash the script wrote. Nothing in the SDK negotiates a
version, so a pinned copy degrades silently against a newer server, and that
hash is the only drift signal there is:
[widget-security](widget-security.md#detecting-drift).

#### The first inbox

```
docker compose exec -T \
  -e INBOX_NAME=Example -e WEBSITE_URL=https://example.com \
  -e ALLOWED_DOMAINS="https://example.com, https://*.example.com" \
  -e BUSINESS_NAME=Example \
  rails bundle exec rails runner - < tools/rails/add-website.rb
```

`ALLOWED_DOMAINS` must not be blank. A blank value removes the framing
restriction rather than defaulting closed, which leaves any site free to embed
the widget, and the script refuses one for that reason. What the value produces
is a Content Security Policy `frame-ancestors` header, an embedding control with
no bearing on spam:
[inboxes-and-identity](inboxes-and-identity.md#allowed-domains). The script also
sets `hmac_mandatory`, so an identity presented without a valid hash is rejected
with a 401; anonymous conversations still work with it on.

Then the assignment rule:

```
docker compose exec -T -e INBOX_NAME=Example \
  rails bundle exec rails runner - < tools/rails/auto-assign.rb
```

The inbox setting called auto assignment does not cover this. It is round robin
over agents the presence tracker currently reports as online, so a queue
answered by one person leaves conversations unassigned for exactly the hours
nobody has the dashboard open. A rule on `conversation_created` carries no such
condition, and the script assigns anything already waiting as well.

Two tokens come out of the inbox and they go to different places. The website
token is public and belongs on every embedding page. The HMAC token is a secret
that the script deliberately does not print: read it from **Settings**,
**Inboxes**, the inbox, **Configuration**, and put it only where a server signs
identities. Anyone holding it can sign any identity, which means pulling another
visitor's history onto a contact they control.

#### Publishing DNS

Go back to the five checks in [the private window](#the-private-window) and
confirm all of them. Then create the record, pointing at the address that
survives a rebuild of the host.

In topology A the origin serves both 80 and 443, so the edge's TLS mode can stay
whatever the rest of the zone needs. The exception is a strict mode that
verifies the origin's certificate: install one from the edge provider's origin
CA and point the proxy at it instead of its internal authority.
See [providers](providers.md#the-edge).

Topology B inverts this step, and was not verified. The proxy gets its
certificate from a public authority, which needs the hostname to resolve first.
The private window then has to be held by the firewall rather than by DNS: allow
80 and 443 from your own address only, complete every step above, and open those
ports to the world afterwards. Test that sequence before relying on it.

#### Verifying

Outside-in first, which proves what an attacker sees:

```
BASE_URL=https://chat.example.com EXPECT_VERSION=4.17.1 \
  EXPECT_SDK=./sdk/sdk.js tools/verify.sh <website token>
```

Then the database, which proves the settings no page displays:

```
docker compose exec -T rails bundle exec rails runner - < tools/rails/audit.rb
```

Every line must read `ok`. Neither run substitutes for the other, and the
dashboard substitutes for neither. Each website token you pass to `verify.sh`
loads the widget once, creating one throwaway anonymous contact in that inbox.

Four checks neither tool can make:

| Check | Why it has to be manual |
| --- | --- |
| A forged `chatwoot-widget:` message from another origin does nothing | needs two origins and a real browser: [verification](verification.md#the-forged-message-test) |
| The conversation cookie carries no `Domain` attribute | read it in the browser's storage panel: [inboxes-and-identity](inboxes-and-identity.md#the-cookie-and-its-scope) |
| A password reset arrives and passes SPF, DKIM and DMARC | needs a real mailbox, and its headers |
| An attachment uploads, lands in the bucket and downloads again | the CLI probe never exercises the library's upload path |

Read [verification](verification.md#claims-that-were-not-verified) before you
tell anyone the installation is safe.

#### What to write down

Keep these in the repository rather than on the host, because the point of
several of them is to survive the host:

- The pinned image digest, and which release it is.
- The provider answers from
  [the probe questions](providers.md#the-questions-and-how-to-probe-them), each
  with the date you measured it.
- The SRI string, and the upstream `sdk.js` hash for this release.
- Where `SECRET_KEY_BASE` and the three encryption keys are backed up. Not here,
  and not on the installation.
- The risks you accepted instead of fixing: a storage key wider than the bucket,
  an origin reachable without going through the edge, the unfixed article-viewer
  XSS, message previews crossing a push relay.

That last line is the one that gets skipped. A risk someone wrote down is a
decision with a name against it; the same risk unwritten is something the next
person finds and has to re-litigate. With the digest recorded,
[upgrades](upgrades.md#pinning-a-release) is what changes it.
