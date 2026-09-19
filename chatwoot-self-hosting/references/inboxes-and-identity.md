# Inboxes and visitor identity

How to arrange accounts and inboxes, restrict who may embed a widget, and keep
one visitor as one contact across several origins.

Everything here was read in Chatwoot 4.17.1. The paths and line numbers are the
ones in that release, and none of these behaviours are a documented contract.


#### One account

Run one account, with one inbox per trust boundary. Every isolation property
that matters is already per inbox. `website_token`, `hmac_token`,
`hmac_mandatory` and `allowed_domains` are columns on `channel_web_widgets`
(`db/schema.rb:712-731`), both tokens carry UNIQUE indexes, and
`has_secure_token` generates each one per row (`web_widget.rb:47-48`). Five
websites are five embed snippets, five independent HMAC secrets (the per-inbox
key that signs a visitor identity) and five separate origin lists, inside one
login and one conversation list.

Nothing gates multi-account. There is no such flag in `config/features.yml`,
premium or otherwise. It is still the wrong shape for this use, and the reason
is not the friction of switching.

The decisive mechanism is in
`app/javascript/dashboard/helper/actionCable.js`, lines 82 to 84:

```
isAValidEvent = data => {
  return this.app.$store.getters.getCurrentAccountId === data.account_id;
};
```

Every incoming realtime event is compared against the account the dashboard
currently has selected, and dropped otherwise. A new conversation in an account
you are not looking at produces no badge, no toast, no sound and no bell entry.
Push and email can
cross accounts, but only after you join every inbox as an `InboxMember` and
enable `conversation_creation` for each account: the shipped default is
assignment only, and these conversations arrive unassigned. With stock
settings, a second account notifies you of nothing while you are looking at the
first.

The rest is friction. The account switcher costs two clicks plus a full page
reload (`window.location.href`). There is no cross-account conversation view
and no cross-account search, because every route is nested under
`/accounts/:account_id/` and `SearchService` is scoped to `current_account`.

Three consequences of one account are worth accepting deliberately rather than
discovering.

1. Contacts merge silently on email inside an account
   (`uniq_email_per_account_contact`). The same person contacting two of your
   sites becomes one contact.
2. An inbox-scoped agent can still search every contact. The contact branch of
   `SearchService` has no inbox filter, so hiring someone for one project does
   not contain them to it.
3. `inbound_email_domain` is per account, so the installation has one
   reply-parsing domain however many inboxes it has. See
   [email](email.md#receiving-is-a-second-provider).

Separate billing or separate staff per brand is a different problem, and
account separation does not solve it. One installation has one set of operator
mail, one branding and one super admin whatever the account count, so that case
wants separate installations. A staging copy is the same answer for a different
reason: a second account sharing real traffic mixes test contacts into the real
ones, and the merge on email is silent.

Turn on `conversation_unread_counts` while you are setting the account up. It
ships off, and without it the sidebar shows no per-inbox unread badges. See
[install](install.md#account-settings).

##### One inbox per trust boundary

The unit is the trust boundary, not the domain name. Surfaces that should share
one visitor history share one inbox, and their origins all go in that inbox's
`allowed_domains`. Surfaces that should not see each other's conversations get
their own inbox and their own tokens.

| Surface | Inbox | Why |
| --- | --- | --- |
| A marketing site and the application behind it | One website inbox, both origins in `allowed_domains` | One inbox is what keeps one visitor one contact across them |
| A second site with its own visitors | Its own website inbox | Its own tokens, its own origin list |
| A customer subdomain such as `tenant.app.example.com` | Its own inbox and tokens | Containment, not continuity |
| Replies by email | An email-channel inbox alongside | Only an email channel gets a per-inbox From address |

A visitor sees their earlier conversations only inside one inbox, and only once
their identity has been verified. That second condition is the one people miss;
[Signing an identifier](#signing-an-identifier) explains it.


#### Creating a website inbox

`tools/rails/add-website.rb` creates or updates one inbox with the hardened
settings. Run it again with changed values rather than editing the inbox in the
dashboard, so the settings for each site live in one place you can read.

```
docker compose exec -T \
  -e INBOX_NAME=Example -e WEBSITE_URL=https://example.com \
  -e ALLOWED_DOMAINS="https://example.com, https://app.example.com" \
  -e BUSINESS_NAME=Example \
  rails bundle exec rails runner - < tools/rails/add-website.rb
```

It refuses to run unless the account count is exactly one.

Both hardened settings ship off. The schema annotation in
`app/models/channel/web_widget.rb` reads `allowed_domains :text default("")`
and `hmac_mandatory :boolean default(FALSE)`, so an inbox created any other way
has neither until somebody sets them.

`allowed_domains` carries the origins that may embed the widget, and the script
refuses a blank value, because blank means no restriction at all. See
[Allowed domains](#allowed-domains).

`hmac_mandatory: true` makes an identity without a valid hash fail with a 401.
Without it, verification is opt-in per request, which is worth reading in the
code before you decide: see
[What mandatory HMAC forces](#what-mandatory-hmac-forces). It is safe on an
inbox that mostly serves anonymous traffic. `hmac_mandatory` appears nowhere in
the conversations, messages, events or widgets controllers, and the update path
returns early when no identifier is supplied, so anonymous chat, the pre-chat
form and email collection all keep working with it on. It constrains identity
binding, not conversations.

`pre_chat_form_enabled: false` is a choice about how you join a visitor's
threads together. The pre-chat form and the auto-injected email-collect box
both route to `ContactIdentifyAction`, so either of them joins an anonymous
thread to a later signup by email address. Turn the form on if you have no
server that can sign identifiers, and accept that a visitor who never gives an
email leaves a thread that is orphaned permanently: there is no automatic
repair. Leave it off when you carry a signed identifier instead.

`business_name` sets the display name on outbound mail. It is the only part of
the From line a widget inbox controls, which is the whole subject of
[email](email.md#the-dead-end-column).

The script also adds every user in the account to the inbox as an
`InboxMember`. Membership is what makes a new conversation notify the operator.
An inbox nobody belongs to still collects conversations, silently.

##### Matching by name, without case

The lookup is `find_by('lower(name) = ?', name.downcase)`, and the reason is a
failure that is easy to repeat. With an exact-case match, an inbox renamed in
the dashboard stopped matching, so running the setup again built a second inbox
beside the first. The new inbox got its own `website_token` and its own
`hmac_token`, because `has_secure_token` runs per row, and the settings you
thought you had just changed sat on an inbox no page was embedding. Matching
without case makes a rename survive the next run.

The script's other guard is the channel type: an existing inbox of any other
kind aborts the run rather than being converted.

##### Reading the HMAC token

Neither the creation script nor the rotation script prints the HMAC token. Both
print the website token, which is public, and both point at
Settings > Inboxes > (inbox) > Configuration for the other one. Whoever holds
the HMAC token can sign any identity, which means reading a visitor's
conversation from before they signed up. A terminal keeps scrollback, and
script output gets pasted into places it should not be.


#### Allowed domains

A blank `allowed_domains` does not merely fail to add a restriction. It deletes
the header that would otherwise carry one. This is `allow_iframe_requests` in
`app/controllers/widgets_controller.rb`, lines 79 to 86:

```
if @web_widget.allowed_domains.blank? || embedded_from_non_web_origin?
  response.headers.delete('X-Frame-Options')
else
  domains = @web_widget.allowed_domains.split(',').map(&:strip).join(' ')
  response.headers['Content-Security-Policy'] = "frame-ancestors #{domains}"
end
```

With a list, the response carries a Content Security Policy `frame-ancestors`
directive, the header that tells a browser which pages may frame a document.
With a blank list, `X-Frame-Options` is deleted and nothing replaces it, so any
site may embed the widget.

The value is a list of origins, scheme included; the code splits on commas and
strips each entry. List every origin that should embed the widget and nothing
else. Wildcards such as `https://*.example.com` work, so a product with one
subdomain per customer does not need one entry per customer.

Know the limits of this control, because its name suggests more than it does.
It acts in the browser, on a page that tries to frame your widget, and that is
all it does. Nothing in `api/v1/widget/` reads it. The widget API answers any
request carrying a valid website token, from any origin, and the website token
is public because it sits in the embed snippet on every page. So
`allowed_domains` is anti-embedding, not anti-spam, and it is not what stops a
visitor claiming another identity. That is `hmac_mandatory`, and the two are
set together for a reason: see rule 6 in
[The eleven rules](../SKILL.md#the-eleven-rules).

`tools/rails/audit.rb` asserts that every widget inbox has a non-blank
`allowed_domains` and `hmac_mandatory` set, because neither is visible on any
page you would think to check.

##### The mobile web view exception

The condition above has a second arm, `embedded_from_non_web_origin?`, defined
just below it. The comment on it gives the intent, which is mobile web views:

```
return false unless @web_widget.allow_mobile_webview?
origin = request.headers['Origin']
origin.blank? || origin == 'null' || origin&.start_with?('file://')
```

A per-inbox flag named `allow_mobile_webview` therefore makes the framing
restriction skip any request whose `Origin` header is absent, is the literal
string `null`, or starts with `file://`. Those three cases are wider than
mobile web views. A null origin is also what a sandboxed iframe presents, so an
inbox with the flag on has weaker framing protection than its domain list
suggests.

Leave the flag off unless a mobile web view needs it, and where it is on, read
the domain list as a partial statement rather than the whole rule.

This was read in the code at 4.17.1 and has not been tested against a live
installation.


#### The cookie and its scope

The widget keeps its conversation in a cookie on the page's own host.
`setCookieWithDomain` passes `domain: baseDomain`, and js-cookie 3.0.5
`continue`s on any falsy attribute, so leaving `baseDomain` unset means no
`Domain=` attribute at all, which means a host-only cookie. That is both the
default and the answer.

There is no safe middle value. RFC 6265 domain matching includes every
subdomain of the value you set, so a `Domain=` that unifies `example.com` and
`app.example.com` also covers `tenant.app.example.com` and every other name
under it. What travels in the cookie is a live session, not a tracking id.
Widening it hands one visitor's conversation to any page served on any
subdomain the value covers, including subdomains a customer controls.

`localStorage` is not an alternative. It is per origin, with no cross-origin
read, so it fails in the same place for the same reason.

The consequence of a host-only cookie looks like a bug the first time you see
it, so expect it. `WidgetsController#build_contact` mints a fresh `Contact` and
`ContactInbox` on widget load, before anyone types, which gives you throwaway
contacts per browser, per host, per inbox. The `cw_user_*` cookie is never sent
to the server: it is a client-side dedupe guard, and its absence on a new host
is exactly what lets `setUser` run there.

Set nothing in `chatwootSettings` that widens the cookie:

```
<script>
  window.chatwootSettings = { position: 'right', locale: 'en', darkMode: 'auto' };
  // Never set baseDomain: without it the widget cookie stays on this host only.
</script>
<script
  src="https://chat.example.com/packs/js/sdk.js"
  integrity="sha384-<the hash of the SDK you serve>"
  crossorigin="anonymous"
  async
  onload="window.chatwootSDK.run({ websiteToken: '<website token>', baseUrl: 'https://chat.example.com' })"
></script>
```

The `integrity` attribute pins the patched SDK you serve, and changing that
file means changing this hash on every embedding page at the same time. See
[widget-security](widget-security.md#rolling-out-a-new-hash).


#### Signing an identifier

Continuity comes from an identifier your application owns, signed with the
inbox HMAC token. The cookie cannot do it, and the sections above say why.

`ContactIdentifyAction` matches on identifier, then email, then phone, scoped to
the account. `ContactMergeAction` then moves conversations, messages and
contact inboxes onto the surviving contact. Unique indexes
`uniq_identifier_per_account_contact` and `uniq_email_per_account_contact` back
the match.

One switch is easy to miss.
`Api::V1::Widget::BaseController#conversations` returns history from other
contact inboxes only when `@contact_inbox.hmac_verified?`, and always scoped to
a single `inbox_id`. The hash is therefore not only an anti-impersonation
control: it is what lets the visitor see their own earlier thread after they
move to a new origin. Without it the merge still happens server-side, and the
visitor is shown a blank widget while their history sits in the dashboard.

The scoping in `app/controllers/api/v1/widget/base_controller.rb` runs both
ways: once a contact inbox is `hmac_verified`, the conversation list is scoped
to contact inboxes that are also `hmac_verified`. A verified session and an
unverified one see different conversation sets. Know that before turning
mandatory HMAC on over an inbox that already carries traffic, because a visitor
who was talking to you unverified and comes back verified does not see the
thread they remember.

After the `chatwoot:ready` window event, identify the visitor:

```
window.$chatwoot.setUser(identifier, { name, email, identifier_hash });
```

Compute the hash on a server, never in the page. This is what the server
compares it against, `valid_hmac?` in
`app/controllers/api/v1/widget/contacts_controller.rb`:

```
def valid_hmac?
  expected_hash = OpenSSL::HMAC.hexdigest(
    'sha256',
    @web_widget.hmac_token,
    params[:identifier].to_s
  )
```

So your application computes a hex HMAC-SHA256 keyed with the inbox HMAC token
over the identifier string:

```
identifier_hash = hex( HMAC-SHA256( key = inbox HMAC token, message = identifier ) )
```

Nothing else goes into it. No timestamp, no nonce, no account id. That cuts two
ways. It is trivial to compute correctly in any language, and it is trivial to
compute for any identifier at all, so the token is the whole secret: whoever
holds it can impersonate any visitor for as long as it stands.

Generate the pair server-side only, and treat the endpoint that issues it as an
authentication surface. Anyone holding a valid identifier and hash can write
any email onto that contact and pull an unclaimed contact's history onto it.

`hasUserKeys` requires at least one of `avatar_url`, `email` or `name`, so an
anonymous `setUser` needs a placeholder name to be accepted at all.

Call `window.$chatwoot.reset()` when the user signs out. Your own sign-out
clears your session and leaves the widget's alone, so without `reset()` the
next person at that browser opens the previous person's conversation.

##### What mandatory HMAC forces

The setting is not a nicety, and the gate shows why.
`should_verify_hmac?`, in the same controller:

```
def should_verify_hmac?
  return false if params[:identifier_hash].blank? && !@web_widget.hmac_mandatory
  return false if params[:custom_attributes].present? && params[:identifier].blank?
  true
end
```

On an inbox without `hmac_mandatory`, a client that simply omits
`identifier_hash` is not verified at all. Verification is opt-in per request
unless the inbox forces it, which makes the signature something an attacker
declines to provide. That is the whole argument for rule 6 in
[The eleven rules](../SKILL.md#the-eleven-rules), and it is why the creation
script sets the flag rather than offering it.

Mandatory HMAC still leaves anonymous traffic alone.
`validate_hmac_for_identified_update` returns early when no identifier is
supplied, and the comment on it gives the reason: an anonymous pre-chat update
carrying only a name, an email or custom attributes has to keep working. What
the flag governs is binding a conversation to an identity, not every write the
widget makes.

The path it protects is rebinding. `a_different_contact?` compares the stored
identifier against the supplied one, and that comparison is where an unsigned
client would otherwise move a conversation onto another person's contact.

##### Never the email address

An email address as the identifier trips `merge_contacts?`, which silently
drops the attribute. You get two contacts and no error, which is why this one
is usually found weeks later. Use a stable opaque internal id as the
identifier, and pass the email as an attribute, which is where
`ContactIdentifyAction` looks for it.

##### Two ways to join the surfaces

Email capture costs no engineering. Enable the pre-chat form or the
auto-injected email-collect box on the anonymous surface; both route to
`ContactIdentifyAction`, and when the visitor later signs up with the same
address the threads join. The merge here is a deliberate `from_email` lookup
before the write, not a side effect of the unique index. If the visitor never
gives an email, the anonymous thread is orphaned permanently.

Identifier carry is the robust version. Mint a random visitor id on the
marketing site, sign it on a server you own, and `setUser` with it plus a
placeholder name. Carry the id to the application at signup, and store it on
the account row server-side rather than in browser storage, so it survives a
device change and an email change. After verification, `setUser` again with the
same identifier plus the real email and name. On a customer subdomain, hand the
same identity down through whatever configuration that subdomain already
receives from your application.

There is a risk to decide in writing. If your signer signs any identifier
handed to it, someone can claim another visitor's anonymous contact. What they
gain is one pre-signup transcript. Bind the identifier to the session that
created it, or accept the exposure explicitly and record the decision.

##### The page-URL leak

The SDK reports the full `document.location.href`: on conversation create, on
every message, on every attachment and on every widget event, so it reaches
webhooks as well as the dashboard, and it persists in
`additional_attributes.referer`. There is no configuration that suppresses it.

On a customer subdomain those URLs carry the customer's own project and task
names, which is a different disclosure from the one you signed up for. Two
options exist: do not run the SDK on tenant origins, or patch
`onLocationChangeListener` to report `location.origin`. You already serve your
own SDK, so the second option is one more line in the same patch, and the same
build rule applies to it, including the compressed variants. See
[widget-security](widget-security.md#the-compressed-variant-trap).

##### The programmatic surface

Verified in the shipped SDK at 4.17.1:

```
window.$chatwoot.toggle('open');                 // open or close the panel
window.$chatwoot.toggleBubbleVisibility('hide'); // hide the default launcher
window.$chatwoot.setUser(identifier, { email, name, avatar_url, identifier_hash });
window.$chatwoot.setCustomAttributes({ plan: 'pro', instance_status: 'running' });
window.$chatwoot.setLocale('de');
window.$chatwoot.setColorScheme('dark');
window.$chatwoot.reset();                        // call on sign-out
```

Hiding the default bubble and driving the panel from your own control is one
call each.

##### Which value is secret

| Value | Secret | Goes to |
| --- | --- | --- |
| The installation base URL | no | every embedding page |
| The website token | no | every embedding page |
| The SDK integrity hash | no | every embedding page |
| The inbox HMAC token | yes | server-side secret stores only |

The website token is public by construction, since it sits in the snippet on
every page that embeds the widget. Nothing about your installation should
depend on it being hard to find. The HMAC token is a signing key, so keep it
where you keep signing keys.


#### Rotating the HMAC token

Rotation invalidates every hash already issued. Until each signer holds the new
value, `setUser` with an old hash is rejected, a mandatory-HMAC inbox answers
401, and visitors lose the cross-origin history that `hmac_verified?` gates.
Nothing is lost permanently: the contacts and conversations stay, and they
become reachable again as soon as the signers agree.

Do it in this order.

1. Rotate with `tools/rails/rotate-hmac.rb`. It prints the first characters of
   the old and new values and the length, which is enough to confirm the change
   without putting the token in the terminal.
2. Read the replacement from Settings > Inboxes > (inbox) > Configuration.
3. Deploy it to every place that signs identities, at once. A signer left on
   the old value is a surface where identity quietly stops working.

The website token does not change, so no embedding page needs editing and no
integrity hash moves.


#### Assigning conversations

Leave the inbox setting called auto assignment off, and know what it is before
you decide that. It is round robin over agents the presence tracker currently
reports as online. From
`app/services/auto_assignment/agent_assignment_service.rb`:

```
def find_assignee
  round_robin_manage_service.available_agent(allowed_agent_ids: allowed_online_agent_ids)
end

def online_agent_ids
  online_agents = OnlineStatusTracker.get_available_users(conversation.account_id)
  online_agents.select { |_key, value| value.eql?('online') }.keys if online_agents.present?
end
```

`allowed_online_agent_ids` carries upstream's own comment, which says round
robin is performed only over online agents, by intersecting the online set with
the allowed member ids. The other half is in
`app/services/auto_assignment/inbox_round_robin_service.rb`, where
`get_member_from_allowed_agent_ids` returns nil for a blank set. So when nobody
is reported online, the allowed set is empty, the round robin returns nil, and
the conversation is left unassigned. Nothing queues it for a later pass.

For what it was built for, that is correct. Round robin serves a staffed rota,
and on a rota it hands work to people who are actually there. It is the wrong
tool for a queue answered by one person, because the hours you most need the
notification are exactly the hours the presence tracker reports nobody online.

An automation rule on `conversation_created` carries no presence condition:

```
rule: Assign <inbox> to the operator
  event      conversation_created
  condition  inbox_id  equal_to  <inbox id>
  action     assign_agent  <agent id>
```

`tools/rails/auto-assign.rb` writes that rule. It refuses to run unless the
account has exactly one user, because a rule that names one agent has to choose
between them otherwise. See
[hardening](hardening.md#the-single-operator-model) for the team version and
for what else the single-operator assumption touches.

The rule fires on creation and never revisits anything, so conversations that
arrived before it existed are never matched by it. They have to be assigned
once, by hand. Read the query into an array before you assign:

```
waiting = inbox.conversations.where(assignee_id: nil).to_a   # materialise first
waiting.each { |conversation| conversation.update!(assignee: agent) }
```

Assigning a conversation stops it matching `assignee_id: nil`. Iterate the
relation lazily and the loop walks a result set it is changing underneath
itself, which skips rows. The array is read once, before the first write.

Assignment and membership answer different questions. The rule decides whose
queue a conversation lands in; `InboxMember` decides who gets told about it.
Set both, or you get assigned conversations nobody hears about.

---
