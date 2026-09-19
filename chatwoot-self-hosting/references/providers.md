# Providers: what Chatwoot needs from each component

What to require of Postgres, object storage, mail, the edge and the host, the
two topologies those requirements produce, and the combinations known to fail.

Every Chatwoot behaviour below was read in **Chatwoot 4.17.1**. Provider
behaviour is a different kind of claim, so each measured one arrives with what
it was measured on and when. That is the whole of what it proves. Providers
change defaults, so treat every answer as a fact about your stack on the day you
took it, and measure again after moving any component.

#### Postgres

Chatwoot needs Postgres 14 or later. Upstream's own compose file ships 16. The
version floor bites during the first schema load rather than at connection
time, so a cluster that connects cleanly can still refuse to be installed into.

Permission is the usual obstacle, and connection count is rarely one: the
application draws around 15 connections with the shipped pool settings, while
its schema creates extensions and tables that a managed cluster does not let an
application role create.

##### The five extensions, and who may create them

The schema needs five, not one:

| Extension | Used for |
| --- | --- |
| `pg_stat_statements` | query statistics |
| `pg_trgm` | trigram text search |
| `pgcrypto` | cryptographic functions |
| `plpgsql` | the procedural language, present in a stock server already |
| `vector` | embedding columns |

Chatwoot's schema enables all five itself. On a managed cluster that step fails,
because only a privileged role may create an extension. Creating them first, as
the admin role your provider gave you, turns the schema's own attempt into a
no-op, which is all `tools/templates/db-init.sql` does.

One image is measured. Running that script against a fresh container created all
five without error:

```
pg_stat_statements 1.10, pg_trgm 1.6, pgcrypto 1.3, plpgsql 1.0, vector 0.8.6
image pgvector/pgvector:pg16, fresh container, 2026-09-19
```

A local container is the easy case, because nothing in it withholds permission.
The run settles what that image carries and says nothing about any managed
cluster. What it does settle is the choice of image for topology B: the stock
`postgres` image carries no `vector` at all.

Availability and permission are two separate questions, and a managed cluster
commonly answers yes to the first and no to the second:

```
SELECT name FROM pg_available_extensions
 WHERE name IN ('pg_stat_statements','pg_trgm','pgcrypto','plpgsql','vector');
SELECT extname FROM pg_extension ORDER BY extname;
```

The first query says the server could create it. The second says somebody has.
Neither says your application role may. The only answer that counts is whether
`db-init.sql` runs to the end without an error.

Creating `pg_stat_statements` as the admin role of a managed cluster is on
[the unverified list](verification.md#claims-that-were-not-verified). It
succeeded on the cluster topology A used, and it is the one extension a provider
is most likely to hold back, because it is loaded through
`shared_preload_libraries` rather than created on demand.

##### Ownership, or the grants that stand in for it

From Postgres 15 onwards the `public` schema belongs to the database owner, and
only the owner may create objects in it. Migrations create tables in `public`.
So the application role either owns the database:

```
ALTER DATABASE chatwoot OWNER TO chatwoot;
```

or it gets the same ability by explicit grant, which is what a provider that
refuses to hand over ownership leaves you with:

```
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL ON SCHEMA public TO chatwoot;
```

Write the fallback into the preparation script rather than deciding between them
by hand. `db-init.sql` attempts the transfer, catches `insufficient_privilege`,
prints a notice and grants instead, then prints the resulting owner so you can
read which path it took. It also runs unattended with no psql variable set,
where the role defaults to `chatwoot`, and honours `-v approle=<role>` when you
pass one.

```
db-init.sql, image pgvector/pgvector:pg16, fresh container, 2026-09-19
unattended run: ok      -v approle: honoured
ownership transfer: succeeded      grant fallback: not exercised
```

So the transfer path has been watched and the fallback path has not. It is there
for a managed cluster that refuses the transfer, which is the case nobody has
observed. Read what the script prints rather than assuming which branch ran.

#### The port

Several managed providers do not listen on 5432. The managed cluster topology A
used listens on 25060.

Getting this wrong produces the least helpful failure in the whole
installation. The container entrypoint runs a `pg_isready` loop against the
host and port you configured, and a wrong port is indistinguishable to it from
a database that has not finished starting. It waits, and nothing in the log
says "wrong port", because from the entrypoint's side nothing is wrong yet. So
read the port off your provider's connection details, write it into
`POSTGRES_PORT`, and treat an entrypoint that never gets past its readiness
probe as a port problem until you have disproved it.

#### Statement timeouts

A provider default in the low tens of seconds is enough to kill a migration and not
enough to notice in normal use. The managed cluster topology A used defaults to
14 seconds, and a single migration on a table with real rows in it runs longer
than that. Upstream knows: its own Procfile runs the prepare step with
`POSTGRES_STATEMENT_TIMEOUT=600s`. The Docker upgrade documentation omits it.

Do not put `POSTGRES_STATEMENT_TIMEOUT` in `.env`. The low default is what
protects the live application from one runaway query, and raising it for every
process to make one command work is the wrong trade. Pass the raised value to
the prepare command alone. See
[upgrades](upgrades.md#the-statement-timeout) for the command, and for what to
do when a migration is killed halfway.

#### SSL, and the setting that does not exist

Chatwoot's `database.yml` has no SSL setting, and Chatwoot has no environment
variable of its own that turns encryption on for the database connection. What
it has is libpq (the Postgres client library underneath Rails), which reads
`PGSSLMODE` from the process environment. Setting that in `.env` reaches three
places at once: the Rails processes, the Sidekiq processes, and the
entrypoint's readiness probe. Use `PGSSLMODE=require` for a managed cluster,
and drop the variable in topology B, where the connection never leaves the
host.

`sslmode` end to end against the managed cluster topology A used is on
[the unverified list](verification.md#claims-that-were-not-verified): the
variable was set, and the connection was never inspected on the wire to confirm
what it negotiated.

#### The connection pool

`RAILS_MAX_THREADS` sets threads per Rails process, and `SIDEKIQ_CONCURRENCY`
sets jobs in flight per Sidekiq process. Each is also that process's pool size.
Five each is the shipped shape and is enough for a single-operator
installation. Raise them together with the cluster's connection limit in view,
because Sidekiq holds a connection for the length of a job.

#### Object storage

Chatwoot writes attachments through Active Storage. Set
`ACTIVE_STORAGE_SERVICE=s3_compatible` for a non-Amazon S3-compatible store: it
reads the `STORAGE_*` variables. The value `amazon` reads a different set of
variables, so a half-migrated configuration silently picks up neither.

The bucket must be private. Chatwoot serves attachments through its own
authenticated routes, and a public bucket hands every attachment to anyone who
guesses a key.

##### Addressing style

`STORAGE_FORCE_PATH_STYLE` decides whether the client addresses the bucket as a
path (`endpoint/bucket/key`) or as a subdomain (`bucket.endpoint/key`). Stores
differ, and some accept both. Getting it wrong produces a 404 against a bucket
that exists, which reads like a missing bucket or a wrong name and is neither.

##### Two problems that are open upstream

A store that a command-line client writes to happily is not proof that Chatwoot
can write to it. Two issues open against `chatwoot/chatwoot` describe that gap,
and both name Cloudflare R2 in their titles, so this is one place where the
provider has to be named rather than generalised:

| Issue | Title, abbreviated | Symptom |
| --- | --- | --- |
| 13299 | images not uploaded or accessible when using `s3_compatible` with Cloudflare | uploads fail silently when the store rejects the AWS SDK's default checksum headers |
| 11766 | client-sent audio returns 404 and `ERR_BLOCKED_BY_ORB` on Cloudflare | a 404 propagation race on read |

Both were open when this was checked. That is why topology A used its own
provider's store rather than R2, despite R2 being the more familiar choice in
that account.

The first has two workarounds in its thread, and the cheaper one is worth
knowing before you rule a store out over it. Patching `config/storage.yml`
inside the image works and costs you an image build and a rebase every release.
Setting the AWS SDK's own environment variables does the same job on a stock
image:

```
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

Two lines in your environment file and no build. Upload a real attachment to
confirm it before you rely on it.

Do not read this as "R2 is broken and everything else works". Read it as
evidence that `s3_compatible` is a compatibility surface with real gaps, and
that the gaps show up in Chatwoot rather than in your storage client. Check both
issues against whatever you are considering, including R2 if its own issue has
since closed. Then upload a real attachment through the dashboard and confirm
the object appears in the bucket and downloads again.
`tools/probe-stack.sh` exercises put, get and delete with the CLI, which is
necessary and, for exactly this reason, not sufficient.

##### The key

Issue a key scoped to the one bucket, then use it before you plan around it.
Some providers refuse to issue one, or issue one that their own API then
rejects. When that happens you have two honest options: use a wider key and
write down in the risk list what else that key can reach, or move the store.
Never assume the scope worked because the console offered the option. Most
providers show a key's secret once, so capture it at creation.

There is a third case that catches people, which is needing a wide credential
for one step rather than for the installation. Creating the bucket can require
more than the key you intend to keep. If you take that route, remove the
temporary credential on every exit path, not at the end of the happy path: a
failed bucket creation, a network timeout or an interrupt all leave it live
against every bucket in the account otherwise. Make a failed removal loud rather
than letting it return quietly. One real cleanup failed silently for exactly
that reason, because the provider's delete command had no flag to force it and
nobody read the exit code.

One more thing about the client rather than the store. The AWS command line
refuses to run without a region even when the store ignores the value entirely,
so a probe run on a machine with no configured region fails before it reaches
your endpoint, and the error reads like bad credentials. Set any region.
`tools/probe-stack.sh` sets one for you.

#### Mail

Sending and receiving are separate products, and Chatwoot needs different things
from each.

For sending, the domain must be verified at the provider, and both senders must
sit on a verified domain: `MAILER_SENDER_EMAIL`, the global sender for
notifications, invitations and password resets, and the account's support email,
where visitor transcripts come from. A provider refuses any other From address
at submission, so an unverified domain fails at send time. Publish SPF, DKIM and
DMARC for every sending domain, and confirm all three pass at a receiver rather
than at the provider's own dashboard.

Receiving is the part that catches people. Chatwoot parses inbound mail through
a channel adapter, and it ships adapters for some providers and not others. A
send-only provider cannot close the loop: a visitor replies to their transcript
and the reply goes nowhere, with no bounce and no error anywhere in Chatwoot.
Expect two providers if you want replies to become messages. See
[email](email.md#receiving-is-a-second-provider) for what that forces.

The SMTP pairing topology A used is on
[the unverified list](verification.md#claims-that-were-not-verified): that
provider is not on Chatwoot's documented provider list, and the configuration
works in principle rather than by report.

#### The edge

In topology A something in front terminates TLS for visitors and forwards to the
origin. Two questions decide the configuration, and both have bitten people.

Before either, something that saves an afternoon of configuration nobody needs.
Chatwoot's realtime endpoint is a websocket, and a reverse proxy worth using
already carries websocket upgrades, sets `X-Forwarded-Proto` and streams
responses without buffering them. A plain `reverse_proxy` to the application
port is the whole configuration. If you find yourself adding upgrade headers,
connection headers or buffering directives, check that your proxy needs them
before you keep them. The shipped templates add exactly one thing beyond the
default, which is the client address header, and they add it because that one
is not something a proxy can get right without knowing your edge.

##### Why the origin serves both ports

An edge reaches its origin over HTTP or over HTTPS depending on how its TLS mode
is set. That setting often belongs to a whole zone, shared with other sites, and
changing it for this installation changes it for them.

So serve both. The proxy template answers on 443 with a certificate and on 80
with the same routes, and it disables the automatic redirect from 80 to 443:

```
{
    auto_https disable_redirects
}
https://{$DOMAIN} { tls internal; import app }
:80                { import app }
```

The redirect is what loops. An edge configured to reach the origin over HTTP
sends a plain request, the origin answers 301 to the HTTPS address, the edge
follows it back to itself, and the visitor gets a redirect loop that reads as a
Chatwoot fault and is not one.

##### The origin certificate

With both listeners serving, the remaining question is whether your edge checks
the origin's certificate. Most TLS modes do not, and a self-signed certificate
from the proxy's own internal authority is enough. A strict mode does check, and
wants one its own origin CA issued: a certificate to install on the host and a
line to change in the proxy configuration. Decide that before you publish DNS
rather than while debugging a failed handshake.

Websocket behaviour through a proxying edge is on
[the unverified list](verification.md#claims-that-were-not-verified). Chatwoot's
realtime updates ride a long-lived websocket at `/cable`, and an edge that
closes idle connections degrades the dashboard in a way that looks like nothing
at all: the page stays up and stops updating. Check that `/cable` accepts an
upgrade from outside, then leave a dashboard open and see whether it still
receives events an hour later.

#### The client address

Chatwoot's rate limits key on the client address. Which address that is depends
on what the proxy puts in `X-Forwarded-For`, and where the proxy got it.

Behind an edge, the connection's own address is the edge's, so every visitor
would share one bucket and one limit. The fix is to copy the address out of the
header the edge sets:

```
reverse_proxy rails:3000 {
    header_up X-Forwarded-For {http.request.header.<your edge's address header>}
    header_up X-Forwarded-Proto https
}
```

Name your own edge's header there. The property that matters is that the edge
overwrites the header on every request, so a client cannot set it. A header the
edge merely forwards is one a client picks for itself, and a client that picks
its own address picks its own rate-limit bucket.

There is a second path to the same problem. If the origin's ports are open to
the internet, as they must be for the edge to reach them, a request can skip
the edge entirely and set the header itself. Narrowing the firewall to the
edge's published address ranges closes it, at the cost of tracking those
ranges. Leaving it open is defensible for a small installation. Either way,
write down which one you chose.

Measure it rather than reasoning about it. Send a request carrying a forged
address header and read which address the origin logged:

```
curl -H 'X-Forwarded-For: 203.0.113.1' https://chat.example.com/api
# then read the origin log for that request
```

If the log says `203.0.113.1`, the limits are decorative.

#### The host

##### Docker, and why compose

Compose is the only deployment path worth using. The alternatives rule
themselves out: Chatwoot's own documentation says not to use the `cwctl`
installer to upgrade an installation running a custom branch, the Helm chart's
documented default image tag is `v2.16.0` against a 4.17.1 application, and a
one-click marketplace image is usually that same chart pinned to a moving tag.

The compose file upstream ships starts Rails, Sidekiq, Postgres and Redis, with
no proxy, no TLS and no healthchecks. The templates in `tools/templates/` are
that file with those three added.

##### Swap

Give the host swap. Two gigabytes alongside eight of RAM is what topology A ran,
against asset and migration work that peaks well above the steady state. Without
swap that peak is an out-of-memory kill, which arrives as a container that died
with no message worth reading. One open memory report against an earlier
release, #13280, is on
[the unverified list](verification.md#claims-that-were-not-verified): watch
memory over the first week rather than assuming either way.

##### An address that outlives the machine

Ask whether your provider gives you an address that detaches from one machine
and attaches to the next. With one, rebuilding the host is a ten-minute
operation and DNS never changes. Without one, every rebuild is also a DNS
change and a propagation wait, which turns "rebuild the box" from routine into
an outage you schedule. In topology A the host holds nothing a rebuild would
lose, so a stable address is the only thing standing between you and a cheap
rebuild.

Two details about these addresses cost an hour each if you meet them cold.
They are usually allocated within one region and can only attach to a machine
in the same one, so allocate it where the machine will live rather than where
you happen to be looking. And a machine holding one answers on two public
addresses, its own and the attached one. Anything that asks the provider "what
is this machine's address" can get either, so tooling that expects a single
answer gets two and fails on the string rather than on the network. Pick the
attached one everywhere, so that SSH, your file copies and DNS all name the
same host.

##### The firewall

The shape is small:

| Direction | Rule | Why |
| --- | --- | --- |
| in | SSH from your address, or from the range it moves within | the tunnel is your admin console |
| in | 80 and 443 from your edge, or from anywhere | the edge has to reach the origin |
| in | nothing else | nothing else is published, so nothing else is reachable |
| out | everything | the application reaches the database, the store and the mail provider |

Publish Rails on `127.0.0.1:3000` in the compose file's `ports`, never on
`0.0.0.0`. Inside the container it still listens on `0.0.0.0`, which is what
lets the proxy reach it over the compose network: a process bound to the
container's own loopback would refuse the proxy's connection. The restriction
that matters is on the published port, not on the bind address, and it is what
lets you run the whole installation before DNS exists.

The SSH row is the one worth deciding rather than copying. A single address is
the tightest rule and it is the right one from a fixed office address or a
jump host. From a residential or mobile connection it is not: an address that
rotates within its provider's range locks you out whenever it moves, and it
moves mid-command as readily as between sessions, which on a provisioning run
leaves the installation in a state you then have to work out.

The alternative is to allow the range your address moves within and to say why
in the risk list. What that costs is real: anyone else on that provider's range
can reach the port. What it does not cost is entry, because the key is what
opens the door and the address only decides who may knock. An installation
locked behind a rule its operator cannot satisfy is not more secure, it is
unadministrable, and the repair is usually done in a hurry.

Two consequences either way. Make the allowed source a setting rather than
something a script infers from whoever is running it, or a repeat run will
silently narrow your access to the address you happened to have that day. And
keep a one-command way to repoint the rule, because you will want it at the
moment you are least able to think.

#### Topology A managed services

Postgres and object storage are managed. An edge terminates TLS for visitors.
The host runs Rails, Sidekiq, Redis and a proxy, and holds no state that
matters.

```
visitor -> edge (TLS) -> host: proxy :80/:443
                              -> /packs/js/sdk.js  : patched file on disk
                              -> everything else   : rails :3000 (loopback)
                         rails, sidekiq -> redis (in compose)
                         rails, sidekiq -> managed postgres
                         rails, sidekiq -> object store
                         sidekiq        -> smtp
```

This is the shape that was built and measured. The stack topology A was
verified on: a DigitalOcean droplet, that provider's managed Postgres and
object storage, Cloudflare at the edge, and Resend for outbound mail. The
requirements above are what to look for in any substitute.

One shipped file still names one of them, and it is deliberate.
`tools/templates/Caddyfile` sets the client address from `CF-Connecting-IP`,
because a working default beats a placeholder for the one setting whose wrong
value produces no error at all. Change it to your own edge's header before you
trust any rate limit. Everything else provider-specific in this skill is a
placeholder. See [the client address](#the-client-address).

What you get is managed backups, point-in-time recovery, a database fork to
rehearse upgrades against, and a host you can destroy and rebuild. What you pay
is four bills, four sets of credentials, and a private network path that has to
work before the first migration runs.

Templates: `tools/templates/compose.yaml`, `tools/templates/Caddyfile`,
`tools/templates/env.template`, `tools/templates/db-init.sql`.

#### Topology B one box

Postgres, Redis and file storage live on the host. The proxy answers visitors
directly and gets a certificate from a public authority.

```
visitor -> host: proxy :443 (public certificate), :80 redirects
                 -> /packs/js/sdk.js : patched file on disk
                 -> everything else  : rails :3000 (loopback)
            rails, sidekiq -> postgres (in compose, pgvector image)
            rails, sidekiq -> redis (in compose)
            rails, sidekiq -> /app/storage (a volume)
            sidekiq        -> smtp
```

**This topology was not verified.** Topology A is the one that was built and
measured. Treat what follows as a design that needs testing, and never report a
topology B installation as hardened on the strength of this file. What else in
this skill rests on an untested claim is listed in
[verification](verification.md#claims-that-were-not-verified).

One piece of it is measured: the database image carries all five extensions and
`db-init.sql` runs cleanly against it, on the conditions recorded under
[the five extensions](#the-five-extensions-and-who-may-create-them). A working
database container is not a working installation, so the rest stands untested.

Four differences change how you work:

1. The Postgres image must carry the `vector` extension, which the stock
   `postgres` image does not and `pgvector/pgvector:pg16` does. Same requirement
   as on a managed cluster, met by choosing the image instead of running a
   preparation script as an admin role.
2. Storage is a volume at `/app/storage`, mounted by both Rails and Sidekiq
   because both write to it. With `ACTIVE_STORAGE_SERVICE=local` it is the only
   state a rebuild cannot recreate from the database.
3. The proxy holds a real certificate, so port 80 must redirect rather than
   serve, which inverts the rule in topology A. It also means the hostname has
   to resolve before a certificate can be issued. Holding the installation
   private until it is hardened then falls to the firewall instead of to DNS.
   See [install](install.md#publishing-dns).
4. Backups, point-in-time recovery, the disk and the Postgres major upgrade are
   yours. Rehearsing an application upgrade needs a copy of the volume rather
   than a managed fork: see
   [upgrades](upgrades.md#rehearsing-without-a-fork).

Templates: `tools/templates/compose.single-box.yaml`,
`tools/templates/Caddyfile.origin-tls`, `tools/templates/env.template`,
`tools/templates/db-init.sql` (which runs unattended from the container's initdb
directory, where the role defaults are already right).

#### Known bad combinations

Check this list before choosing a component because you have used it before.

| Combination | What happens | Reference |
| --- | --- | --- |
| The `latest` or `latest-ce` tag | the tag is repointed on every push to master and migrations never run on their own, so a pull leaves new code on an old schema | [upgrades](upgrades.md#pinning-a-release) |
| The Helm chart at its documented default image tag | `v2.16.0` against a 4.17.1 application | Chatwoot docs |
| A one-click marketplace image | usually that chart, pinned to a moving tag | Chatwoot docs |
| `cwctl` for upgrading a custom branch | ruled out by Chatwoot's own documentation | Chatwoot docs |
| A managed database on a non-default port, left unconfigured | the entrypoint's readiness probe waits for ever with no useful error | [the port](#the-port) |
| A provider `statement_timeout` in the low tens of seconds | a migration is killed partway | [upgrades](upgrades.md#the-statement-timeout) |
| An `s3_compatible` store never exercised through the application, per issues 13299 and 11766 | uploads fail silently on a checksum; a 404 race on read. Both issues name Cloudflare R2, and both have workarounds | [object storage](#object-storage) |
| A send-only mail provider, alone | replies to transcripts are lost, silently | [email](email.md#receiving-is-a-second-provider) |
| An edge header any client can set, used as the client address | every client picks its own rate-limit bucket | [the client address](#the-client-address) |
| A redirect from 80 to 443 on the origin, behind an edge that speaks HTTP to it | redirect loop | [both ports](#why-the-origin-serves-both-ports) |
| Skipping from a 3.x release to 4.2 or later on an installation with real users | the migration fails; a stop at v4.1 is mandatory, and upstream closed the report as not planned | issue 12088 |
| SSO or SAML on a CE image | the SAML code is entirely under `enterprise/`, which the CE build deletes, and the dashboard ships a paywall component for it; password plus a second factor is the path | read at 4.17.1 |

One reminder rather than a combination: whether the dashboard survives a strict
Content Security Policy in front of it is on
[the unverified list](verification.md#claims-that-were-not-verified).

#### The questions, and how to probe them

`tools/probe-stack.sh` asks all eight and prints `NOT MEASURED` plus the manual
method for anything it cannot reach. Run it before you commit to a stack, and
again after changing any part of one.

| Question | How the probe answers it | What the answer decides |
| --- | --- | --- |
| Version and extensions | `SHOW server_version`, then `pg_available_extensions` and `pg_extension` for all five | whether the schema will load at all |
| The port | reads the port out of the connection string you gave it | whether the container ever finishes starting |
| Who may create extensions and hand over ownership | reports the connected role and whether it is a superuser | whether `db-init.sql` needs its grant fallback |
| The statement timeout | `SHOW statement_timeout` | whether migrations need the raised value, which they almost always do |
| Object storage | a put, a get and a delete through the CLI | necessary, not sufficient; a real attachment upload is the test that counts |
| Mail | no probe | send a password reset, confirm SPF, DKIM and DMARC pass at the receiver, then ask separately whether the provider can receive |
| The client address | sends a request with forged address headers | read the origin log for that request; the probe cannot see the log |
| A stable address | no probe | whether a rebuild is ten minutes or a DNS change |

Two of these have no probe on purpose. Mail needs a delivery to a real mailbox
and an inspection of the headers there, and the client address needs the
origin's own log, which the probe cannot read from outside. Anything that prints
`NOT MEASURED` is a question you still owe an answer to, and never one that
passed.

Record each answer with the date you took it, so that when you next move a
component you can tell which decisions rested on facts that no longer hold. Then
go to [the build order](../SKILL.md#build-order), written against these
answers.
