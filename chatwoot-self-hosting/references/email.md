# Email identity and delivery

What address mail leaves from, what cannot be changed about it, and why
receiving replies is a second purchase.

Everything here was read in Chatwoot 4.17.1. The paths and line numbers are the
ones in that release, and none of these behaviours are a documented contract.


#### The compromise

A web-widget inbox cannot have its own From address. Transcript mail to a
visitor comes from `accounts.support_email`, which is account-wide. Five widget
inboxes in one account send from one address, and the only per-inbox part of
the identity is `business_name`, the display name that sits in front of it. A
visitor of one brand gets mail that reads as that brand and comes from the
address of the installation.

Decide what that costs you before you design around it. The design that looks
like the way out is a column that cannot be reached and will not survive the
next release, and the two designs that do work are both larger than they first
appear: an email-channel inbox per brand, or a separate installation per brand.

Set the account address once, after onboarding:

```
docker compose exec -T -e SUPPORT_EMAIL="Support <no-reply@mail.example.com>" \
  rails bundle exec rails runner - < account-setup.rb
```

Where each kind of mail gets its From line:

| Mail | From address | Per-inbox override |
| --- | --- | --- |
| Widget transcript to a visitor | the account support email | none, only the display name |
| Reply from an email-channel inbox | that inbox's own address | yes, through per-inbox SMTP |
| Notification, invitation, password reset | `MAILER_SENDER_EMAIL` | none, and none per account either |

Only the middle row is yours to set per site. The other two are one value each
for the whole installation, which is rule 8 in
[The eleven rules](../SKILL.md#the-eleven-rules).

##### Where each value lives

Four places hold the four pieces of the identity.

| Value | Where it lives | Changed by |
| --- | --- | --- |
| The account support address | `accounts.support_email` | `tools/rails/account-setup.rb` |
| The per-inbox display name | `inboxes.business_name` | `tools/rails/add-website.rb` |
| The operator sender | `MAILER_SENDER_EMAIL` in the environment | editing the environment and restarting |
| An email inbox's own address | that channel's SMTP settings | the inbox's configuration page |

Keep the values you set with the rest of the installation's record. Written in
four places and displayed together nowhere, an unexpected From line is
otherwise a search.

##### What you can and cannot buy with this

| You want | Build | It costs |
| --- | --- | --- |
| Live chat on several sites | Website inboxes only | One From address for every transcript, per-inbox display names |
| A real per-brand From address | An email-channel inbox per brand | A verified sending domain per brand, and IMAP configured before the SMTP fields appear |
| Replies that land back in the conversation | A receiving provider Chatwoot has an adapter for | A second provider, and one reply-parsing domain for the whole account |
| Operator mail that names each brand | Nothing available | Choose a sender that names the installation |


#### The dead end column

There is a per-inbox column `inboxes.email_address`. Two methods in
`app/mailers/conversation_reply_mailer.rb` read it, `reply_email` and
`inbox_from_email_address`, and the second falls back to
`@account.support_email`. Anyone reading the schema finds the column within a
minute, and it looks like the answer. It is inert, for four reasons.

1. Nothing but the Rails console can write it. `inbox_attributes` in
   `app/controllers/api/v1/accounts/inboxes_controller.rb`, lines 195 to 202,
   permits exactly `name`, `avatar`, `greeting_enabled`, `greeting_message`,
   `enable_email_collect`, `csat_survey_enabled`, `enable_auto_assignment`,
   `working_hours_enabled`, `out_of_office_message`, `timezone`,
   `allow_messages_after_resolved`, `lock_to_single_conversation`, `portal_id`,
   `sender_name_type` and `business_name`, plus a nested `csat_config`.
   `email_address` is absent, and the string does not appear anywhere in that
   controller, so the column is unreachable from the UI and from the API.
2. Nothing in `app/`, `lib/`, `enterprise/` or `db/migrate/` ever writes it
   either.
3. It is inert unless the account's `inbound_emails` flag is off, and that flag
   defaults on.
4. Upstream's replacement keeps the same behaviour. `Email::FromBuilder`, at
   `app/builders/email/from_builder.rb`, sits behind the
   `reply_mailer_migration` feature flag, which is per account and ships
   disabled. Its `build` method opens with a guard on the channel type:

```
def build
  return sender_name(account_support_email) unless inbox.email?
```

The first reason settles it today and the fourth settles it for later. A column
no request can write is not an unfinished feature waiting for a UI, and the
replacement already written for this code path returns the account support
email for a widget inbox before any per-inbox logic runs. The limit is not an
artefact of old code waiting to be modernised. It survives the modernisation.

Do not build on it.


#### Email-channel inboxes have their own address

Per-inbox SMTP (the protocol Chatwoot uses to hand outbound mail to a provider)
is real and free in Community Edition. `email_from` in
`app/mailers/conversation_reply_mailer_helper.rb` is one line:

```
email_oauth_enabled? || email_smtp_enabled? ? channel_email_with_name : from_email_with_name
```

An inbox whose channel has SMTP or OAuth configured sends from the channel's
own address, and everything else falls back to the account address. So an
email-channel inbox gets genuine per-site identity: `team@example.com` for one
brand and `hello@other.example` for another, out of one installation and one
conversation list.

That line is preceded by an early return into `Email::FromBuilder` for an
account with the `reply_mailer_migration` feature enabled, the replacement
named in [the dead end column](#the-dead-end-column), and the builder spells
the same question out in more detail. It gives the channel's own address to an
inbox with IMAP and SMTP both enabled, to one using Google or Microsoft OAuth,
and to a forwarding inbox with its own SMTP. For an inbox with IMAP but no
SMTP, or forwarding without SMTP, it gives the channel's address only when
`verified_for_sending` is true. Everything else gets the account support email.

Per-brand identity therefore has a condition attached: the inbox needs a
sending path of its own, or it needs to have been verified for sending. An
email inbox that reads mail and has no sending path falls into that second
branch, and its replies carry the account address until it is verified. Someone
who configures an email inbox for per-brand identity and gets the account
address back is usually standing in that branch.

One UI detail costs an afternoon if you do not know it. The SMTP panel stays
hidden until IMAP (the protocol that reads mail out of a mailbox) is enabled
(`ConfigurationPage.vue:382`). Configure IMAP first, and the SMTP fields
appear. An operator looking for the From address on a half-configured inbox
finds no such field and concludes the feature is premium.

##### Two inboxes per website

A site that wants both live chat and mail from its own address needs two
inboxes: a website inbox for the widget, and an email-channel inbox beside it.
They sit in the same account, so contacts still merge on email address across
them and the conversation list still shows both. See
[inboxes and identity](inboxes-and-identity.md#one-inbox-per-trust-boundary).

Build the second inbox only when you want the address. It is a mailbox to
configure, credentials to store and rotate, and a second place a conversation
can arrive from. A site whose visitors only ever chat does not need it, and a
transcript from the account address is a smaller compromise than a mailbox
nobody watches.


#### Operator mail is global

Notification, invitation and password-reset mail comes from
`MAILER_SENDER_EMAIL`. There is no account override and no inbox override, and
separate accounts do not fix it: the value is read for the installation, not
for the account the recipient belongs to.

Pick a value that names the installation rather than one brand. Every operator
of every brand you run here sees the same sender on every password reset they
will ever ask for, and an address that claims one brand is confusing on the
other ones.

This is also the address most likely to be left pointing at a domain nobody
verified, because no conversation ever goes through it. It is exercised only
when somebody is locked out, which is the worst moment to find out that the
mail does not arrive.


#### What custom_reply_domain and custom_reply_email are

They are Community Edition, not premium, and they are visibility toggles in the
UI. The server accepts `domain` and `support_email` through PATCH with no flag
check, so the underlying values are writable whether or not the toggles show.

There is no `custom_email_domain_enabled` column. That name is an i18n key,
which is why a grep for it turns up a translation string and no behaviour, and
why the feature reads as gated when nothing gates it.

The end-to-end behaviour of `custom_reply_domain` was not verified. Treat it as
unconfirmed until you have tested it on your own release: see
[verification](verification.md#claims-that-were-not-verified).


#### Deliverability

Every domain you send from needs SPF, DKIM and DMARC. Publishing the records is
the easy half. The half that matters is that they pass at the receiver, on a
real message, read at a real mailbox somewhere else.

##### The three records

SPF (Sender Policy Framework) is a DNS record naming the hosts allowed to send
for the domain. Add your provider's include, and remember that a domain can
have exactly one SPF record: a second one is a failure, not an addition.

DKIM (DomainKeys Identified Mail) is a signature over the message, checked
against a public key your provider tells you to publish in DNS. Your provider
generates the key pair. Your job is to publish the record it gives you and to
leave it alone afterwards.

DMARC (Domain-based Message Authentication, Reporting and Conformance) tells
receivers what to do when the first two fail, and requires that at least one of
them align with the domain a human sees in the From line. Alignment is the part
that catches people out: a message can carry a valid SPF pass for the
provider's own domain and still fail DMARC for yours.

A provider usually refuses mail from a domain it has not verified, at
submission, so that first failure is loud. The quiet failures come later, from
receivers that accept the message and file it as spam. Only a real delivery
test tells you which of those you have.

##### How many domains you can verify

Check how many verified root domains your plan allows before you promise a
per-brand From address to anyone. That number caps how many distinct sending
domains the installation can have, whatever Chatwoot is willing to configure.
An email-channel inbox with an address on an unverified domain is a
configuration that looks complete and delivers nothing.

Sending through an SMTP provider that is not on Chatwoot's documented provider
list works in principle and was not verified. If you use one, prove it with a
real password reset before you rely on it, and see
[verification](verification.md#claims-that-were-not-verified).


#### Receiving is a second provider

Sending and receiving are separate products, and buying one does not get you
the other. A send-only provider cannot parse replies: there is no inbound side
to read, and 4.17.1 ships no adapter for one. Nothing turns the reply into a
message, so it is lost, with no bounce and no trace in the conversation. The
visitor believes they answered you.

What Chatwoot needs is an adapter for whatever receives. The MX record (the DNS
record that names the host accepting mail for a domain) for the reply domain
must point at SES, Mailgun, Postmark, SendGrid, or a local Postfix relay. Check
the adapter list on the release you run rather than on this one. Expect two
providers: one that sends, one that receives.

The sending domain and the reply domain need not be the same name. Only the
domain that receives needs an MX pointing at the adapter, so an installation
that sends from one domain and parses replies on another is a normal shape, not
a workaround.

##### One reply domain per account

`inbound_email_domain` is per account, so the installation has one
reply-parsing domain however many inboxes it has. A per-brand reply domain is
not available inside one account, which is the same wall the From address runs
into and for the same reason. See
[inboxes and identity](inboxes-and-identity.md#one-account).

##### If you choose not to receive

For a small installation this is a defensible choice and it saves a provider,
an MX record and a class of parsing bugs. Record it as a limit rather than
leaving it to be discovered: a reply to a transcript is lost, silently.

Then say so in the address itself. `no-reply@mail.example.com` tells a visitor
what will happen to a reply before they write it. `support@example.com`
promises something the installation is not delivering.


#### What to test

Run these after the installation is public, and again after every upgrade. All
four fail in ways the dashboard shows as success.

- A password reset arrives at an address outside your own domain, and passes
  SPF, DKIM and DMARC at the receiver.
- A widget transcript arrives, its From line carries the account support
  address, and the display name is that inbox's business name.
- A test message from each email-channel inbox arrives with that inbox's own
  From address.
- A reply to that message lands back in the conversation it came from.

The last one is the whole receiving question in a single check, and it is the
one usually skipped, because everything before it worked.

Read the results at the receiver rather than at the provider. Open the message
source in the receiving mailbox and find the authentication results header,
which states each of the three by name with a pass or a fail. A provider's own
dashboard reports what it sent, which is the half you already know.

Put the mail tests in the upgrade rehearsal too, against the copy of the data,
so a release that changes a mailer is caught before it changes yours. See
[upgrades](upgrades.md#rehearsing-without-a-fork).

---
