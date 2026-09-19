# Verification

What to check from outside, what to check inside the database, what only a
person can check, and what nobody checked at all.

Everything here was verified against Chatwoot 4.17.1. The assertions are about
that release, so re-read anything load-bearing against your own.

#### Two proofs, and what neither of them is

Outside-in checks prove what an attacker sees. They run over the public address,
through whatever your edge and proxy do to a request, and they are the only
thing that tells you a path is actually closed. They cannot see a single
setting: a 404 from the proxy looks identical whether the underlying feature is
disabled or wide open behind it.

The database audit proves the settings that no page displays. It runs inside the
Rails container and reads the rows directly. It cannot tell you whether any of
that is reachable from the internet, because it never leaves the host.

Run both. Rule 11 in [the eleven rules](../SKILL.md#the-eleven-rules) is this
pair, and the reason for it is that each one's blind spot is the other's whole
subject.

The dashboard is neither proof. It shows what it was configured to show. It has
no view of the installation configuration row that decides whether signup is
open, no view of the Redis key that arms the onboarding endpoint, no count of
platform applications, no indication of whether the encryption keys that make
second factors storable are present, and no knowledge of which file your proxy
serves at the SDK path. A green dashboard on an installation with an open
onboarding endpoint looks exactly like a green dashboard on a closed one.

Run the pair after first setup, after every upgrade, and after any change to the
proxy, the SDK or an inbox.

#### Outside-in

`tools/verify.sh` runs these. It needs `curl` and `openssl` and nothing else, so
it runs from a laptop on a different network, which is where it should run:

```
BASE_URL=https://chat.example.com \
EXPECT_VERSION=4.17.1 \
EXPECT_SDK=./sdk/sdk.js \
tools/verify.sh <website token> [<website token> ...]
```

Without `EXPECT_VERSION` or `EXPECT_SDK` the script reports what it found rather
than asserting it, which is useful the first time and useless afterwards. Set
both once you know the answers.

`EXPECT_SDK` points at your own build. The skill ships the patch and the build
script, and no built `sdk.js`, so there is no published integrity value to
compare against and none to expect. The only correct hash is the one
`tools/patch-sdk.sh` printed for the release you run, from the build you made.
See [widget-security](widget-security.md#rolling-out-a-new-hash).

| Check | Expected result | What a failure means |
| --- | --- | --- |
| `GET /api`, `version` field | the release you pinned, without the leading `v` | The running image is not the one you think. See [upgrades](upgrades.md#pinning-a-release) |
| `POST /api/v1/accounts` | 404 | Account creation is reachable. Both API versions are checked because closing one does not close the other |
| `POST /api/v2/accounts` | 404 | As above |
| `GET /super_admin` | 404 | The admin console is public, and it has no second factor |
| `GET /super_admin/sign_in` | 404 | The login form is public even if the index is not |
| `GET /monitoring/sidekiq` | 404 | The job console is public |
| `GET /installation/onboarding` | 404 | Anyone can mint a confirmed super admin. Stop and fix this before anything else. See [hardening](hardening.md#the-onboarding-window) |
| `GET /packs/js/sdk.js`, sha384 of the body | the same hash as your patched build | The proxy is serving the image's copy, or a build you did not make |
| The same response's `Access-Control-Allow-Origin` | `*` | Integrity pinning fails closed and the widget never loads. See [widget-security](widget-security.md#rolling-out-a-new-hash) |
| `GET /cable` with websocket upgrade headers | 101 | Realtime is broken, so new conversations arrive silently |
| Per widget inbox: `GET /widget?website_token=...` | a `Content-Security-Policy` header carrying a `frame-ancestors` list. A blank `allowed_domains` sends no such header at all, rather than a wildcard one | That inbox can be embedded by any site. See [inboxes-and-identity](inboxes-and-identity.md#allowed-domains) |
| Per widget inbox: `PATCH` to the widget `set_user` endpoint with an unsigned identifier | 401 | A visitor can claim another visitor's identity |

Two notes on the last two rows. The checks need the inbox's public website
token, which is the value already on every embedding page, so there is no secret
in the command line. And each one loads the widget once, which creates one
throwaway anonymous contact in that inbox. That is the documented cost of
running the check, and it is why the contact list has a few visitors named after
your probes.

The 404s are the proxy's, not the application's. Chatwoot answers those paths
happily; the proxy is what refuses them. Test them from outside the network, not
from the host, or you measure the wrong thing. If your edge caches responses,
check that a 404 you just saw is not a cached copy of one from a previous
configuration.

One thing the script deliberately does not attempt: reading the message guard
out of the served SDK. The bundle is minified, and any pattern you match on is a
pattern a different minifier output would miss. Prove the guard by hand instead.

#### The database audit

`tools/rails/audit.rb` runs inside the Rails container and exits non-zero when
any assertion fails:

```
docker compose exec -T rails bundle exec rails runner - < tools/rails/audit.rb
```

It prints one line per assertion. See
[install](install.md#running-the-rails-scripts) for how the other Rails scripts
are run, which is the same way.

| Assertion | What it proves |
| --- | --- |
| Account signup is disabled in the database | The installation configuration row reads exactly `false`, and the service that gates registration agrees. The row wins over the environment after seeding, and `off`, `0` and `f` all read as enabled. See [hardening](hardening.md#flags-that-are-not-booleans) |
| Installation onboarding is closed | The Redis key that arms the unauthenticated super-admin endpoint is blank. It re-arms on any restore into an empty database, which is why this is checked every time and not once |
| No platform apps exist | No platform token exists that could create confirmed users or mint single sign-on links |
| Exactly one user exists | Nobody was invited, and no signup got through |
| Exactly one account membership exists | The one user belongs to one account, so no second account is quietly collecting conversations |
| Every user has a second factor turned on | The dashboard login is not a password away from the conversation history |
| The encryption keys are configured | The three encryption variables are set. Without them second-factor secrets cannot be stored at all, so the previous assertion could not have been satisfied honestly |
| No API-channel inboxes exist | The public inbox endpoints resolve only API channels, so with none of them the whole path answers 404 |
| No help-centre portals exist | There is no public portal, which also removes the reason a visitor would ever be on the article route. See [widget-security](widget-security.md#the-second-cve) |
| Every account shows unread counts | The per-inbox unread badge feature is on. It ships off, and without it the sidebar shows nothing per inbox. See [install](install.md#account-settings) |
| Every widget inbox restricts framing | No inbox has blank allowed domains. Blank removes the framing restriction rather than defaulting closed |
| Every widget inbox requires signed identities | No inbox accepts an unsigned identity, so no visitor can claim another |

Twelve assertions. Not all of them are universal: two encode the single-operator
model, and three encode choices this skill made about the shape of the
installation rather than security facts.
[hardening](hardening.md#the-single-operator-model) sorts them and says what a
team changes. Whatever you change, edit the assertion to match reality rather
than deleting it: a deleted assertion stops reporting and stops failing.

The two per-inbox assertions iterate over every widget inbox, so a new inbox
created without allowed domains fails the audit the next time it runs. That is
the safety net for the one setting that fails open.

#### Checks no script can do

Each of these needs a browser, a mailbox or a phone.

The served SDK is what the page loads. Open an embedding page, look at the
network panel, and confirm the request for `sdk.js` goes to your host, carries
an `integrity` attribute, and succeeded. A refused integrity check shows as a
blocked request and an absent widget, which is easy to miss if you were not
watching for it.

[The forged message test](#the-forged-message-test), below.

The signup route is gone from the interface, and not merely refused by the API.
Open the login page in a private window and look for a registration link or a
create-account form. The outside-in checks prove the endpoint refuses a POST,
which is the half that matters for security, but a visible form that fails on
submit is a different problem and one only a person sees. If it is still there,
the stored configuration row is not what you think it is: see
[hardening](hardening.md#flags-that-are-not-booleans).

The conversation cookie has no `Domain` attribute. Open the application panel,
find `cw_conversation`, and read its domain column. A value there means the
session is offered to every subdomain the value covers. See
[inboxes-and-identity](inboxes-and-identity.md#the-cookie-and-its-scope).

Mail arrives and authenticates. Trigger a password reset, then read the received
message's headers and confirm SPF, DKIM and DMARC all pass at the receiver. A
message that arrives is not a message that passes; the difference shows up later
as a spam folder.

A reply comes back. Reply to a transcript and confirm it lands in the
conversation. This only works if something receives mail at that domain, which
is a separate product from sending. See
[email](email.md#receiving-is-a-second-provider).

Attachments round-trip. Upload an image in a conversation, confirm the object
appears in the bucket, and download it again from the dashboard. A bucket that
accepts a command-line upload can still reject the library's.

The mobile app connects and receives a push. Enter the installation address,
log in, and send yourself a message from another browser.

Run the first three after every SDK change. Run the rest after setup and after
any change to mail, storage or the edge.

#### The forged message test

This is the only check that proves the served SDK carries the message guard. The
build-time spec proves the patch works in the tree you built from; this proves
the file your visitors receive is that build.

Set it up once and keep it:

1. Put a page on an origin that is not your site and not the Chatwoot host.
   `https://probe.example.com` will do, and a local file served over `file://`
   will not, because it has no usable origin.
2. Have that page frame one of your real embedding pages in an iframe.
3. Have the outer page post a message to the frame whose data is a string
   beginning with `chatwoot-widget:` and whose JSON body names the
   `popoutChatWindow` event with a `baseUrl` pointing at the probe origin.

Expected result on a patched SDK: nothing happens. No window opens, no request
reaches the probe origin, and the widget carries on working.

Expected result on an unpatched SDK: a popout window opens on the probe origin,
carrying the visitor's conversation cookie in the query string. If you see that,
the page is loading the image's copy of the file rather than yours. Check the
proxy route. If you serve the SDK from inside a custom image, check
[widget-security](widget-security.md#the-compressed-variant-trap) as well: the
compressed copies are served first, and patching only the plain file leaves them
untouched.

Keep the probe page. It takes a minute to write and it is the regression test
for every future SDK rollout, including the ones where the patch applied cleanly
and silently did nothing.

Two points of care. Run it against a real embedding page rather than a page you
wrote for the test, because what you are testing is the file that page loads.
And run it after the hash rollout is complete, not during the overlap window,
or a browser refusing the new file on integrity grounds will look like the guard
working. See
[rolling out a new hash](widget-security.md#rolling-out-a-new-hash).

#### What to record when it passes

A passing run is a measurement of one installation on one day. Write down what
it was a measurement of, because the next upgrade starts from that record rather
than from memory.

| Record | Why the next person needs it |
| --- | --- |
| The image digest, and the release tag it resolved to | The starting point of the next upgrade, and the only way to tell later what was actually running |
| The sha256 of upstream's shipped `sdk.js` for that release | The drift comparison. Without the previous value there is nothing to diff against. See [widget-security](widget-security.md#detecting-drift) |
| The sha384 of your patched build | What the outside-in check asserts, and what every embedding page pins |
| The date, and where the checks were run from | An outside-in check run from inside the network proved something else |
| Which unverified claims you resolved, and how | Otherwise the list below stays the same length for ever |
| Which release notes you read | The upgrade path, including any version you cannot skip. See [upgrades](upgrades.md#pinning-a-release) |

Commit the hash files rather than pasting the values somewhere. A hash in a chat
message is a hash nobody can diff next release.

#### Claims that were not verified

Everything else in this skill was read in the source at 4.17.1 or measured
against a running installation. These were not. Treat them as open questions
rather than instructions, and check any one of them before you build on it.

Topology B. The one-box shape was written from the requirements rather than from
a working installation. Nobody stood it up, so the templates for it are
untested: the single-box compose file, its database initialisation and its proxy
configuration are written from what Chatwoot needs and not from what was
observed to work. Topology A is the shape that was built and measured. See
[providers](providers.md#topology-b-one-box).

An undocumented SMTP provider. Sending through a provider that is not on
Chatwoot's documented list works in principle and was **not verified** end to
end.

Creating `pg_stat_statements` as a managed cluster's privileged role. The other
four extensions were created this way; this one was not separately confirmed.

TLS between the application and a managed Postgres cluster, end to end. The
connection works; that every hop enforces the mode was not measured.

Websocket timeouts through a proxying edge. Realtime connects. How the edge
treats a long-lived connection over hours was not measured.

Whether the dashboard survives a strict content security policy. Nobody applied
one to it.

Whether any paid plan makes installation branding per-account. See
[hardening](hardening.md#branding).

Custom reply domain and custom reply email, end to end. The server accepts the
values. What the whole flow does with them was not followed through.

An open memory report against 4.9.0, issue 13280. Not reproduced, and not ruled
out on 4.17.1.

Whether the dashboard's new-account button also depends on the signup flag. It
gates nothing on the server either way, so the answer changes nothing about what
you configure. See [hardening](hardening.md#flags-that-are-not-booleans).

When you resolve one of these on your own installation, write down what you did
and what you saw. An answer with no method behind it becomes the next person's
unverified claim.
