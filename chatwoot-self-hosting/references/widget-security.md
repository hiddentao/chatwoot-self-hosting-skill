# The widget SDK: the vulnerability, the patch, and keeping it

What CVE-2025-12245 does, why one patched file closes it without forking the
image, and what it costs to keep that file correct across releases.

Everything below was read at Chatwoot 4.17.1. The SDK changes with the release,
so re-read the upstream file before carrying any of this to another version.

#### CVE-2025-12245

The advisory is GHSA-hgg8-54gw-8v33, published 2025-10-27. It names the function
`initPostMessageCommunication` in `app/javascript/sdk/IFrameHelper.js`, says the
manipulation of `baseUrl` leads to an origin validation error, and records that
the vendor was contacted early and did not respond in any way. At 4.17.1 it is
disclosed and unfixed.

Do not use the advisory to decide whether you are affected. Its text says
"chatwoot up to 4.7.0", it carries no machine-readable affected range at all,
and it names no fixed version. Read the file on your own release instead: the
three properties below were still present at 4.17.1, which is numerically well
past the version the advisory names. An operator who checks the advisory, sees a
range that appears not to cover them, and stops there will conclude they are
safe while running the vulnerable code. Checking takes one request:

```
# Does your release still take the popout host out of the message?
curl -fsS https://raw.githubusercontent.com/chatwoot/chatwoot/<your tag>/app/javascript/sdk/IFrameHelper.js \
  | grep -n 'popoutChatWindow: ({\|e.origin\|e.source'
```

A `popoutChatWindow` handler destructuring `baseUrl` from its argument, with no
`e.origin` or `e.source` test anywhere in the file, means the release is
vulnerable whatever the advisory's version string says.

The recorded severity is medium, with a CVSS vector of
`AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N`. Both halves of that are worth arguing
with on your own installation: `C:L` for a conversation session handed to
another origin, and `I:N` for a handler that writes an attacker's session into
the visitor's browser. Score it yourself rather than inheriting the number.

Every embedding page loads `/packs/js/sdk.js`, which is built from
`app/javascript/sdk/IFrameHelper.js`. That file is 344 lines at v4.17.1, and
three places in it matter. The line numbers below were read in that file at that
tag on 2026-09-19.

`initPostMessageCommunication`, lines 100 to 113, installs a single
`window.onmessage` handler on the embedding page. Its guard, lines 102 to 107,
applies two tests to each message: is `e.data` a string, and does it start with
the prefix `chatwoot-widget:`. Lines 108 to 111 then parse the remainder as JSON
and call the function named by the message's `event` field. Nothing on that
path reads `e.origin`, and nothing reads `e.source`. Any message carrying the
prefix is handled as though the widget iframe had sent it.

`sendMessage`, lines 93 to 99, posts to the widget frame with a target origin of
`'*'`. Whatever ends up in that frame is offered the message contents.

The `popoutChatWindow` handler, lines 235 to 239, is declared as
`({ baseUrl, websiteToken, locale })`, so the host comes out of the message. The
handler reads the visitor's `cw_conversation` cookie and passes it, with that
host, to the popout helper, which builds a URL on the host with the cookie in
its query string. The cookie is the visitor's widget session. A message naming a
host the sender controls therefore delivers the session to that host: theft.

The `loaded` handler writes the same cookie from a value carried in the message,
so a message can replace the visitor's session with one the sender already
holds: fixation. That handler was not separately located by line number.

Both handlers run on the embedding page, so they run with whatever the embedding
page is worth. On a logged-in application origin, that is the visitor's real
session with your product sitting next to the widget's.

##### Who can drive it

Anything holding a handle to the embedding page's `window` can post to it:

- an iframe on the page, through `window.parent`
- a window that opened the page, through `window.opener`
- any script already running on the page, including a third-party tag

The first two matter most, because neither needs a foothold in your code. An
advertisement slot, an embedded video, a payment frame or a page opened from a
link you do not control is enough. The third is the reason a strict content
security policy on the embedding page is a partial mitigation at best: a tag you
loaded on purpose can also send the message.

#### Why one patched file, and no fork

The instinct after reading the above is to fork the repository, patch the source
and build an image. That buys a rebase on every release and a build to maintain.
Four properties of the upstream build make it unnecessary.

The SDK is a single self-contained bundle. `vite.lib.config.ts` builds it as one
IIFE with `inlineDynamicImports: true`, emitting `public/packs/js/sdk.js`. The
shipped file contains zero dynamic imports and no chunk paths, so there is no
second file that has to agree with the first.

The path is stable and unhashed. `entryFileNames` is the literal
`js/sdk.js`, so the URL does not change between releases. `packs/manifest.json`
is a progressive web app manifest and not a digest map, so nothing else in the
application resolves the SDK through a lookup table you would have to update.

The bundle hardcodes no host. `baseUrl` reaches the SDK only through
`chatwootSDK.run({ baseUrl })`. In the embed snippet the script's `src` and the
configured `baseUrl` are independent knobs, so the page can load the file from
anywhere while still pointing the widget at your installation.

There is no integrity metadata upstream. Nothing signs or hashes the shipped
file, so replacing it at the edge breaks no check that the application makes.

So: serve one patched copy of that file from your proxy, point every embedding
page at it, and run a stock server image. Rule 5 in
[the eleven rules](../SKILL.md#the-eleven-rules) is this arrangement.
`tools/templates/Caddyfile` has the route, which answers `/packs/js/sdk.js` from
a directory on disk and sends everything else to Rails.

Maintenance is close to zero because the code barely moves.
`initPostMessageCommunication` was unchanged from 2020-04-03 to 4.17.1, and the
popout handler from 2022-03-28. The file took seven commits in the two years to
September 2026, and two of those were the origin-validation fix and its revert,
which cancel each other out.

Close to zero is an average, not a promise. A commit reducing the bundle's size
landed on 2026-08-24, three days before 4.17.1 was published, and the patch
still applied because it did not touch the three places that matter. That is the
usual outcome, and it is why the hash comparison is per release rather than per
rebase: the release that moves a part you do care about looks identical until
you diff it.

The three ways out, and what each costs. This file describes the first:

| Option | Per release | What is still exposed |
| --- | --- | --- |
| Serve a patched copy from the proxy | Rebuild the file, rebase the patch if upstream moved the code | The article viewer, which is in the application bundle |
| Fork and build an image | A rebase, an image build and an upgrade rehearsal against your own image | Nothing in the SDK, and the article viewer can be fixed in the same tree |
| Wait for upstream | Nothing | Everything, for as long as the fix takes. The first attempt sat open eighteen months, merged, and was reverted six days later |

#### What the patch changes

`tools/sdk/IFrameHelper.patch` touches one source file and adds one spec. It
makes four changes, at the three places named above. It was confirmed to apply
to v4.17.1 on 2026-09-19: `git apply --check` accepted both hunks and the new
spec file against the tag.

It derives the widget's origin from local configuration:

```
widgetOrigin() = new URL(window.$chatwoot.baseUrl, window.location.href).origin
```

Resolving against `window.location.href` is deliberate. A base URL may be
protocol-relative (`//chat.example.com`) or a path on the same host, and both
forms have to yield an origin rather than throwing. This is the detail that the
open upstream pull request gets wrong, which is why the patch carries a test for
it.

It checks the sender. The message handler now rejects the message unless the
widget iframe exists, `e.source` is that iframe's `contentWindow`, and
`e.origin` equals the widget origin. The existing prefix tests stay. An opener,
a sibling frame or a script on the page fails the source test; a frame at
another origin fails the origin test.

It addresses outgoing messages. `sendMessage` posted to `'*'`, which offers the
message content to whatever ends up in that frame. It now posts to the widget
origin, so the browser drops the message if the frame is somewhere else.

It takes the popout target from configuration. The handler reads only `locale`
from the message; `baseUrl` and `websiteToken` come from `window.$chatwoot`. The
conversation cookie can then only travel to the host you configured, whatever a
message claims.

The patch also adds `app/javascript/sdk/specs/IFrameHelperMessageGuard.spec.js`,
a vitest spec with six tests:

| The test asserts | Which rule it protects |
| --- | --- |
| A message from a foreign origin is ignored, even when its source is the widget frame | the origin check |
| A message carrying the widget origin from any other window is ignored | the source check |
| Messages are ignored when the widget frame is absent | the null-frame case |
| The popout opens on the configured host, never the host in the message | the popout target |
| A protocol-relative base URL resolves against the page | the origin derivation |
| Outgoing messages are addressed to the widget origin only | the outgoing address |

Five of the six fail against unpatched source. That is what makes the spec worth
running: it can tell you that the patch applied but did nothing, which a clean
`git apply` cannot.

#### Upstream history

A fix, pull request 8879, was opened on 2024-02-07 and merged on 2025-08-14,
eighteen months later. It was reverted six days after that, on 2025-08-20, by
pull request 12248. The revert was not a rejection of origin validation. That
implementation's `sanitizeURL` had no success path, so it always returned
`about:blank`, and it compared `'https:'` against `'https'`. It broke the
widget.

Pull request 13240 has been open since January 2026. It is substantially right
and it breaks on a protocol-relative `baseUrl`, which is the case the patch here
covers explicitly.

Neither had landed at 4.17.1. When one does land, the reproducibility gate below
tells you: the shipped bundle's hash changes, and the patch stops applying.

#### Building the file

`tools/patch-sdk.sh` builds it. Give it the upstream tag and the image reference
your server runs:

```
tools/patch-sdk.sh v4.17.1 chatwoot/chatwoot:v4.17.1-ce@sha256:<digest> ./sdk
```

It runs four steps.

1. Extract `/app/public/packs/js/sdk.js` from the pinned image and take its
   sha256. This is the drift record, and it is compared against the hash stored
   from last time.
2. Clone the tag, build the SDK with no changes at all, and compare the result
   to the file extracted in step 1.
3. Apply the patch and run the guard spec.
4. Build again, write `sdk.js`, and print its sha384 Subresource Integrity
   string.

Step 2 is the gate, and it is the reason the script is worth more than a `sed`
command.

##### The reproducibility gate

A build that does not reproduce the shipped file byte for byte tells you nothing
about what the patched build contains. The difference could be the toolchain,
the lockfile, a build-time environment variable, or upstream shipping an image
built from something other than the tag. Until you know which, a patched build
from the same tree is a file you cannot account for, and you would be serving it
to every visitor with the SDK's full access to the page.

So the script stops there. It does not write `sdk.js`, and it exits non-zero.
The skill ships a starting baseline for v4.17.1 in `tools/sdk/upstream.sha256`,
beside the patch:

```
5b1eb8190acffdb5761e4210947478b1b2a6600507e3a117a657cc97d9b592aa v4.17.1
```

If your extraction of the same release gives a different hash, find out why
before going further. The build runs inside a pinned Node image so that your own
machine's toolchain is not part of the answer.

If the patch stops applying to a new release, the script also stops. Read the
upstream file, rebase the patch onto it, and run the script again. That is the
recurring cost of this approach, and in two years of upstream history it came
due rarely.

#### Pinning the file with Subresource Integrity

Serving your own file fixes the vulnerability. Pinning its hash on the embedding
page fixes something else: it stops a changed file on your server, or a changed
file in transit, from running. That matters most on an origin where a live
session is readable by scripts on the page.

The embed snippet:

```
<script>
  window.chatwootSettings = { position: 'right', locale: 'en' };
  // Leave baseDomain unset. The widget cookie then stays on this host only.
</script>
<script
  src="https://chat.example.com/packs/js/sdk.js"
  integrity="sha384-<the hash patch-sdk.sh printed>"
  crossorigin="anonymous"
  async
  onload="window.chatwootSDK.run({
    websiteToken: '<website token>',
    baseUrl: 'https://chat.example.com'
  })"
></script>
```

Two things have to be true for the browser to check the hash rather than refuse
the file outright. The tag needs `crossorigin="anonymous"`, and the response
needs an `Access-Control-Allow-Origin` header that covers the embedding page.
The proxy route in `tools/templates/Caddyfile` sends `*`, and the outside-in
checker asserts it, because without the header integrity pinning fails closed
and the widget simply never loads. See
[verification](verification.md#the-forged-message-test) for what to check by
hand once it is serving.

Leaving `baseDomain` unset in the settings object is unrelated to integrity and
belongs in the snippet anyway. See
[inboxes-and-identity](inboxes-and-identity.md#the-cookie-and-its-scope).

#### Rolling out a new hash

A pinned hash means the file and the pages that load it have to change together.
They almost never deploy together. An `integrity` attribute accepts several
hashes separated by spaces, and the browser runs the file when any one of them
matches, which gives you an overlap window.

Three deploys, in this order:

1. Add the new hash beside the old one everywhere the value is configured, and
   deploy every embedding page. Both hashes are now accepted, and the old file
   is still being served.
2. Put the new `sdk.js` on the server. Pages accept it because of step 1.
3. Remove the old hash everywhere and deploy the pages again.

Skipping step 1 breaks every embedding page at the moment the file changes, and
the failure is silent from the server's side: the browser refuses the script,
the widget never appears, and your logs show a successful 200 for the file.

Do this on any change to the SDK, which in practice means every upgrade that
changes the upstream bundle. `tools/verify.sh` compares the served file against
your local build, so it catches a step 2 that did not happen. It cannot see
which hashes your pages pin, so the overlap window is yours to track. See
[upgrades](upgrades.md#rehearsing-without-a-fork).

#### Detecting drift

There is no version negotiation anywhere in the SDK or the widget. The SDK does
not announce its version to the server, the server does not announce a minimum,
and nothing on either side fails when they disagree.

The consequence is that a pinned SDK degrades silently. Upstream adds a
configuration key, the new widget reads it, your older SDK never sends it, and
the feature is simply absent. No console error, no failed request, nothing in a
log. The same is true of a new event: the widget emits it, your SDK has no
handler, and nothing happens.

The only signal available is the hash of upstream's shipped file. Record it on
every release and compare:

- `tools/patch-sdk.sh` writes the extracted hash to `upstream.sha256` in the
  output directory you gave it, with the tag beside it, and on the next run
  prints whether upstream changed the file since. Give it the same directory
  every time, in your own deployment repository, or the comparison is against
  whichever copy happens to be there.
- When it did change, read the diff of `app/javascript/sdk/` between the two
  tags before you ship the new build. You are looking for new configuration
  keys, new events, and any change to the message handler or the popout path
  that your patch has to account for.
- Then re-run the completeness check below, because a patch that still applies
  is not the same as a patch that still covers everything.
- When it did not change, the patched build you already have is still current
  and the rebuild only confirms it.

Commit the hash file. A hash you did not record is a comparison you cannot make
next release.

##### Checking the patch is still complete

The guard specification proves the four changes the patch makes. It cannot
prove there is no other sender, because it only exercises the senders it knows
about. That matters on a rebase: upstream can add a new place that posts a
`chatwoot-widget:` message from somewhere your single allowed origin does not
cover, and every existing test still passes.

The check is one grep, and it is how the allowed origin was settled in the first
place:

```
# Every place that sends a widget message, on the release you are moving to.
grep -rn "chatwoot-widget:" app/javascript/

# Each hit must be reachable from the one origin the patch allows, which is
# new URL(window.$chatwoot.baseUrl, window.location.href).origin
```

If a hit is a sender the patch does not cover, the patch is incomplete on that
release even though it applied cleanly and its tests passed. Widen the guard
deliberately, or do not ship the upgrade. Run this whenever the upstream hash
moves, and record that you ran it beside the hash.

#### The compressed variant trap

This applies to anyone who builds a custom image rather than serving the file
from a proxy. It costs an evening to find, and it is one more argument for the
proxy route.

The image ships `sdk.js.br` and `sdk.js.gz` alongside `sdk.js`. Rails 7.2.3.1
serves static files with `precompressed: %i[br gzip]` by default, and it checks
`.br` first. Every browser that offers Brotli, which is every browser you care
about, gets the `.br` copy.

Patching `sdk.js` alone therefore serves the patch to nobody. The file on disk
is correct, a `curl` with no `Accept-Encoding` header returns the patched bytes,
and every real visitor still runs the vulnerable bundle. Nothing reports an
error, because nothing is wrong from the server's point of view.

All three variants have to be regenerated together. The Node binary already
inside the image can do the compression. Running `assets:precompile` cannot,
because `node_modules` is deleted from the image during the build.

Serving the file from the proxy sidesteps the whole problem: those requests
never reach Rails, so the precompressed copies in the image are never consulted.
They stay on disk, stale and unread. That is worth knowing if you ever move the
route back, because the stale copies start being served the moment you do.

#### The second CVE

CVE-2025-12246, advisory GHSA-8pv5-qj88-7mx6, published the same day as the
first one and with the same note that the vendor was contacted early and did not
respond. The advisory names the file
`app/javascript/shared/components/IframeLoader.vue` and says the manipulation of
the `link` argument results in cross-site scripting, reachable remotely. That
much is first hand, read from the advisory on 2026-09-19.

What the advisory does not spell out, and what was pieced together from a
write-up that returned 403 when it was read for this skill, is the exact path:
`IframeLoader.vue` binding `:src` to a URL that `ArticleViewer.vue` feeds from
the article route's query parameter, so a value in the URL reaches an iframe
source with no scheme check in between. The file and the parameter are
confirmed; the precise chain between them is not. Read those two components on
your own release before acting on the detail.

The same caution about version strings applies here. This advisory also says
"up to 4.7.0" and names no fixed version, so it is not evidence that a later
release is unaffected.

What can be said with confidence is where the code lives. The article viewer is
part of the widget's Vite bundle, inside the application, rather than the
standalone SDK. Serving your own `sdk.js` does not touch it. Fixing it means
patching the source and building an image, with the rebase-per-release cost that
the rest of this file avoids.

Leaving it unfixed leaves a reflected script injection on the Chatwoot origin,
which is the origin where every visitor's conversation session lives. The
consolation is that reaching a visitor means getting them to open a crafted URL
on that origin, and an installation with no help-centre portal gives them little
reason to be there. The database audit asserts that no portal exists, for this
reason among others.

Decide this one explicitly and write the decision down, with a date and the
release it was made against. It is the kind of accepted risk that turns into an
assumed fix if nobody recorded which it was. If you build an image anyway, read
[the compressed variant trap](#the-compressed-variant-trap) first, and note that
one image build makes other patches cheap: the page URL reporting in the SDK and
the branding job discussed in [hardening](hardening.md#branding) are in the same
tree.

#### What this patch does not do

It does not authenticate the widget iframe's contents. It proves a message came
from that frame at that origin. If the Chatwoot origin itself is running
attacker script, the guard is satisfied by definition, which is why
[the second CVE](#the-second-cve) matters even though it is a different file.

It does not restrict who may embed the widget. That is `allowed_domains` on the
inbox, and it fails open when blank. See
[inboxes-and-identity](inboxes-and-identity.md#allowed-domains).

It does not narrow the conversation cookie. Cookie scope is decided by
`baseDomain` in the page's settings object. See
[inboxes-and-identity](inboxes-and-identity.md#the-cookie-and-its-scope).

It does not prove anything about the file your visitors actually receive. The
guard cannot be read reliably out of a minified bundle, so the served file has
to be checked by hand once per SDK change. See
[verification](verification.md#the-forged-message-test).
