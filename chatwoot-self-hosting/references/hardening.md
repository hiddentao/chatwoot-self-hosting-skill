# Hardening: nobody else may use this installation

Closing a working installation to everyone but its operators, in the order the
gaps have to be closed, and what a team changes.

Every claim here was checked against Chatwoot 4.17.1, reading the source at that
tag. None of it is part of a documented contract, so re-check anything
load-bearing against your own release before you rely on it.

The order matters, and the first item is a footgun rather than a setting: the
window is open from the moment the database is seeded, and the only way to close
it is to walk through it yourself. Everything after it is a setting, and
settings keep.

#### The onboarding window

`app/controllers/installation/onboarding_controller.rb` carries one guard,
`before_action :ensure_installation_onboarding`, and that method is a single
line:

```
redirect_to '/' unless ::Redis::Alfred.get(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
```

That is the whole gate. No authentication of any kind. `create` then calls
`AccountBuilder.new(..., super_admin: true, confirmed: true).perform`, so one
POST is enough, and whoever sends it owns the installation.

`finish_onboarding` deletes the Redis key, which is what closes the window.
Nothing else deletes it, and seeding an empty database sets it again, so the
window is a state the installation can re-enter rather than a phase of first
boot. A restore that leaves the database empty puts you back in it a year later,
on a hostname that resolves.

That method has one other effect worth knowing: with the subscribe box ticked,
it calls `ChatwootHub.register_instance` with the company, the name and the
email you typed. Untick the box if you would rather not send those.

Three things follow.

1. Do the first boot with Rails bound to loopback and no DNS record for the
   hostname. Reach onboarding through an SSH tunnel and complete it there:
   [install](install.md#onboarding-over-a-tunnel).
2. Return 404 at the proxy for `/installation` and `/installation/*`, and leave
   that rule in place for good. It is what protects you after a restore, when
   nobody is thinking about onboarding.
3. Assert the key is gone in the database audit, because no page shows it.

```
# Before DNS exists: reach the private app through the host.
ssh -N -L 3000:127.0.0.1:3000 operator@<host address>
# then open http://localhost:3000/installation/onboarding

# After DNS exists, from anywhere that is not the host:
curl -s -o /dev/null -w '%{http_code}\n' \
  https://chat.example.com/installation/onboarding
# 404
```

`tools/rails/audit.rb` asserts that the same key is now blank. A restore is the
one operation that makes that assertion fail on an installation which has been
safe for months: [upgrades](upgrades.md#restore-and-rebuild).

#### Flags that are not booleans

`GlobalConfigService.account_signup_enabled?` is one comparison:

```
load('ENABLE_ACCOUNT_SIGNUP', 'false').to_s != 'false'
```

One string disables signup. Everything else enables it, including the values
that read like a disabled flag to a person.

| Value in the environment | What the server does |
| --- | --- |
| `false` | signup refused |
| `off`, `0`, `f` | signup enabled |
| unset, or empty | signup enabled |
| `api_only` | signup enabled, and worse than `true` |

`api_only` deserves its own line. It returns a live session with no email
confirmation, so an account created that way is usable immediately by whoever
created it. A flag value chosen to sound restrictive is the most permissive of
the four.

##### Why the row beats the environment

The answer is in `load`, directly above that comparison. It reads the stored
configuration first and returns it when present. Only when nothing is stored
does it fall back to the environment variable, which it then persists with
`InstallationConfig.where(name: config_key).first_or_create`. So the environment
variable is read once, written into a row, and ignored from then on.

Editing `.env` afterwards changes nothing, which is why a `.env` that says
`false` and an installation that accepts signups are entirely consistent with
each other. The only way to tell them apart is to read the row.

Check both the row and the service that reads it:

```
InstallationConfig.find_by(name: 'ENABLE_ACCOUNT_SIGNUP')&.value.to_s == 'false' &&
  !GlobalConfigService.account_signup_enabled?
```

Both halves matter: the first says the stored value is the one string that
works, the second says the application agrees. Outside-in, the same fact is a
refusal on both API versions, so `POST /api/v1/accounts` and `POST
/api/v2/accounts` should both 404. Check the environment, the row and the
endpoint, because each can disagree with the others. A third flag looks like a
gate on the same thing and is not one: see
[the dashboard flag that gates nothing](#the-dashboard-flag-that-gates-nothing).

#### Keeping the admin console off the public internet

`SuperAdmin::Devise::SessionsController#create` calls one thing,
`valid_credentials?`, which finds the record by email and checks
`valid_password?`. There is no second-factor branch anywhere in that file.

Read it beside the operator login. In
`app/controllers/devise_overrides/sessions_controller.rb` the branch is there:
it returns early for a verification request, returns a challenge when the user
has the second factor enabled, and authenticates only after that. Same password,
two doors, a second factor on one of them. Turning the factor on protects the
dashboard and leaves the admin console exactly as exposed as it was.

So the admin console's protection is reachability, and reachability is the
proxy's job. Return 404 for three path families and everything under them:
`/super_admin`, the console itself; `/monitoring`, the background job queue; and
`/installation`, the onboarding window. Answer 404 rather than 403, because a
403 confirms the path exists.

```
# Caddy. Each route is a handle block because handle blocks run before bare
# respond directives.
@private path /super_admin /super_admin/* /monitoring /monitoring/* /installation /installation/*
handle @private {
	respond 404
}
```

You still need the console occasionally. Reach it the way you reached
onboarding, over the SSH tunnel to loopback, where the proxy is not in the path.
That gives one account of who can log in: whoever holds an SSH key on the host
and the admin password. `tools/verify.sh` asks the four paths from outside and
fails on anything but 404. Run it after every upgrade, because a proxy
configuration is a file a deploy can replace without knowing this rule exists.

#### The second factor, and the three keys

`Chatwoot.mfa_enabled?` is exactly `encryption_configured?`. The second factor
becomes available when three environment values are present, and stays
unavailable while any of them is missing:

```
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
```

They are commented out in upstream's `.env.example`, so an installation built by
copying that file has no second factor available and no message saying so: the
option is simply absent from the profile settings. Active Record encryption uses
the three to encrypt and decrypt the stored per-user second-factor secret. The
database holds the ciphertext, and the keys hold the ability to read it. Lose
them and every stored secret becomes unreadable, with no recovery path, which
locks out every operator who has a second factor turned on.

Generate them once, with the installation's own Rails:

```
docker compose run --rm rails bundle exec rails db:encryption:init
```

Then turn the factor on for yourself in Profile settings, Two-factor
authentication, and store the backup codes somewhere other than the machine you
log in from. Back up the three keys with `SECRET_KEY_BASE`, off the
installation: a database restore without them is not a restore.

Two audit lines, because the keys and the enrolment are separate facts:

```
Chatwoot.mfa_enabled?
User.where(otp_required_for_login: false).none?
```

#### Create no platform application

A `PlatformApp` holds a token that creates confirmed users and mints SSO login
links. Both of those walk past the controls above: a user created that way never
goes through signup, and a login link never meets a password or a second factor.

None is seeded, so the correct state is the state you already have, and the
audit holds it there with `PlatformApp.none?`. If you ever do need one, treat
creating it as a decision to write down, with the token stored the way you store
an inbox HMAC token, and a date to delete it.

#### Remain the only account user

Invitations require an `administrator`, which `UserPolicy#create?` enforces, and
they cannot be disabled by configuration. There is no flag, no environment
variable and no account setting that closes the invitation path. The
administrator who can invite is you.

So the control is a count, checked in the database:

```
User.count == 1
AccountUser.count == 1
```

Two counts, because they answer different questions. `User` is who can log in.
`AccountUser` is who is a member of the account, and a user with no membership
still has a password and an API token.

This is the assertion that catches the case nobody plans for: an administrator,
under time pressure, inviting a contractor for an afternoon. The audit turns
that into a failing line at the next run rather than a thing you remember in six
months.

#### Keep the throttling on, and lower it

Rack::Attack, the request-throttling middleware, defaults to on in production.
Leave it on and lower the numbers, because upstream's default is a ceiling for
a large installation rather than a limit for yours.

```
ENABLE_RACK_ATTACK=true
RACK_ATTACK_LIMIT=300               # upstream ships 3000 a minute

ENABLE_RACK_ATTACK_WIDGET_API=true
RATE_LIMIT_WIDGET_CONVERSATIONS=10
RATE_LIMIT_WIDGET_MESSAGES=30
RATE_LIMIT_WIDGET_CONTACTS=60
RATE_LIMIT_WIDGET_LOAD=200
RATE_LIMIT_WIDGET_TRANSCRIPT=5
```

The widget limits decide what an anonymous visitor can cost you, and they are
separate from the global limit. Conversations and messages bound spam.
Transcript bounds outbound mail sent on a stranger's instruction.

Every one of these numbers counts requests per client address, so they are worth
precisely as much as your confidence in that address. A request that reaches the
origin without passing your edge can set the forwarded-address header itself and
pick its own bucket. Measure which header carries the address, and whether a
client can forge it, before you trust any number above:
[providers](providers.md#the-client-address).

#### No help-centre portal, and no API-channel inbox

Both add a public surface you did not ask for.

`/public/api/v1/inboxes/*` resolves only `Channel::Api`, so with no API-channel
inbox the whole family 404s. Creating one opens it, and it is unauthenticated by
design.

A help-centre portal publishes articles, and the widget's article viewer carries
the second CVE. Having no portal is part of why that CVE can be accepted rather
than fixed, so if you add one, revisit that decision:
[widget-security](widget-security.md#the-second-cve).

```
Channel::Api.none?
Portal.none?
```

#### The agent access token is a password

Every user gets an API access token on creation (`after_create
:create_access_token`), and this cannot be disabled in CE. It sits in Profile
settings under Access token.

It exists whether or not you ever use it, and it is a credential for the API
with your account's reach. Treat it the way you treat the login password: never
in a repository, never in a chat, never in a browser extension's configuration.
Having no use for it does not make it go away, so the question is only where the
copy lives.

#### The dashboard flag that gates nothing

`CREATE_NEW_ACCOUNT_FROM_DASHBOARD` gates nothing on the server. It is one
condition in a Vue template. Setting it hides a button; the endpoint behind the
button is unchanged, and anything that speaks to the API directly never sees the
template at all.

This matters because the name reads like a server-side switch, so people set it
and conclude that account creation is closed. Account creation is closed by
`ENABLE_ACCOUNT_SIGNUP` being exactly `false` in the database row, and by
nothing else.

One related question is open. Whether the dashboard's "New account" button also
requires `ENABLE_ACCOUNT_SIGNUP` to be non-`false` was **not verified**. It does
not change what you should do, because the row is the control either way, and it
is listed with the other open questions in
[verification](verification.md#claims-that-were-not-verified).

#### What is unavoidably public

A widget accepts anonymous visitors. That is what a widget is, and no setting
turns it off without turning the widget off. So a public installation carries
two costs that are working as designed.

The first is spam: conversations you did not want, from addresses you cannot
predict. The second is storage growth, and more of it than the conversation
count suggests. A contact and a contact inbox are created when the widget loads,
before anyone types, so every page load from a new browser leaves a row behind.
One outside-in verification run that loads the widget once leaves one throwaway
contact, which is a cheap way to see the rate for yourself.

Four controls exist, and they do different jobs:

- `allowed_domains` per inbox decides which sites may frame the widget. It is a
  CSP `frame-ancestors` header and nothing else, so it limits embedding and not
  abuse of the API behind it. Blank removes the restriction rather than
  defaulting closed. See
  [inboxes-and-identity](inboxes-and-identity.md#allowed-domains).
- The pre-chat form puts a step in front of the first message.
- The upload size cap bounds what one visitor can store.
- The widget rate limits bound the rate, per client address.

Business hours is cosmetic: it changes what the widget says and refuses nothing.
Set the rest against your own tolerance. A marketing site answered by one person
wants tighter numbers than a product with an on-call rota.

#### The single operator model

The scripts and the audit in `tools/` encode one operator, because that is the
installation that was built and measured. Two of the audit's twelve assertions
carry that model, and only those two change for a team:

```
User.count == 1                                      # exactly one user
AccountUser.count == 1                               # exactly one membership
```

The two counts become your roster. Write the expected numbers in, rather than
relaxing the check to a range: an assertion that passes for any count catches
nothing, and the whole point of these lines is to notice an account you did not
add.

Two more look like headcount and are not, so leave them alone. Three others are
not security rules at all: no API-channel inbox, no help-centre portal and
unread counts on are choices about the shape of this installation. Keep them
asserted so a change is deliberate, and change the assertion when you change the
decision.

`PlatformApp.none?` stays at zero however many people you are. A team is a
reason for more users, and never a reason for a token that creates confirmed
users without signup.

`User.where(otp_required_for_login: false).none?` already scales. It says every
user, however many there are, so a new colleague who has not enrolled yet shows
up as a failing line until they do, which is the behaviour you want.

The `Account.count == 1` guard at the top of the other scripts is a separate
decision, and it is about accounts rather than people. Read
[one account](inboxes-and-identity.md#one-account) before you relax that one:
more operators is a team, more accounts is a different installation shape with
its own consequences.

Three other things change with a team, outside the audit.

Invitations stay impossible to disable. With one operator that is a fact you
note and then assert against. With five, an administrator will use it, so the
control becomes review: run the audit on a schedule, and read the count.

Assignment changes shape. Built-in auto assignment is round robin over agents
the presence tracker reports as online, so a single operator gets nothing
assigned during the hours they are not watching. A team with real coverage can
use it as intended. A small team with gaps has the same problem and wants the
same fix: an automation rule on `conversation_created`, which carries no online
condition.

Contacts still merge on email within the account, whoever answers them. Neither
team size nor a second account changes that. See
[inboxes-and-identity](inboxes-and-identity.md#one-account).

#### Branding

Installation branding is not a Community feature, and the widget's "Powered by
Chatwoot" line is part of that. What reconciles it is a daily job,
`Internal::ReconcilePlanConfigService`, which disables `disable_branding` on
every account and resets `INSTALLATION_NAME`, `BRAND_NAME` and `LOGO` to
Chatwoot's own values.

Where that job lives decides whether it runs on your image, and at 4.17.1 it
lives in exactly one place:
`enterprise/app/services/internal/reconcile_plan_config_service.rb`. There is no
copy under `app/`. Upstream's CE publish workflow,
`.github/workflows/publish_foss_docker.yml`, has a step named "Strip enterprise
code" that runs `rm -rf enterprise` and `rm -rf spec/enterprise`, then appends
`ENV CW_EDITION="ce"` to the Dockerfile before building. A service inside a
directory the build deletes cannot run in the image that build produces.

So the widely repeated version of this, that a daily job will reset any branding
you set, does not hold for a `-ce` image. The opposite claim does not follow
either. Whether installation branding you set on a CE image persists **was not
verified**, and the job's absence is a reason to expect it rather than a reason
to promise it. It is on
[the unverified list](verification.md#claims-that-were-not-verified).

Settle it for your own image by waiting, which needs no source reading:

```
# 1. Set INSTALLATION_NAME, BRAND_NAME and LOGO, restart, and confirm the
#    dashboard shows them.
# 2. Look again after 24 hours. Chatwoot's own values back in place means
#    something is still reconciling them on your image.
```

Whether a paid plan makes installation branding per-account could not be
verified either, and per-project branding was not available at any tier that
could be checked. If either matters commercially, get it in writing from
upstream before you design a page around it.

#### Mobile

The official mobile apps connect to a self-hosted installation. On first launch
they ask for an installation URL: enter your own hostname in `domain.com` form,
in place of Chatwoot's cloud address, press Connect, then log in with the normal
credentials.

Two things to know before you promise anyone the app works.

SSO and SAML are not available to you, and the reason is worth knowing because
it is structural rather than a bug someone might fix. Chatwoot does have SAML at
4.17.1, but every server-side part of it sits under `enterprise/`: the user
builder, the settings controller, the account settings model and the OmniAuth
initialiser are all in that tree. The CE build deletes that tree, and the
dashboard ships a paywall component for the feature. The table it needs is in
`db/migrate`, so a CE schema still carries the table with nothing to use it. So
the self-hosted login is a password plus the second factor, which is another
reason the three encryption keys are not optional. On the mobile side the same
limit is reported as `chatwoot/chatwoot-mobile-app` issue 972, "SSO only shows
for app.chatwoot.com", open when this was checked.

That number needs its repository, and so does any other you carry from here. The
mobile application has its own repository and its own issue numbering, while
every other number in this skill is `chatwoot/chatwoot`. Issue 972 in the main
repository is an unrelated feature request about profile name fields from 2020.

Second, `chatwoot/chatwoot` issue 13420, "Invalid URL in mobile app", reported
Connect failing on a self-hosted installation. Read it for the diagnosis rather
than as a live defect: it was closed by a maintainer who attributed it to the
reporter's TLS and domain configuration behind a third-party control panel, and
it was never reproduced against Chatwoot itself. If your own Connect fails, that
thread is a reasonable first place to look at your proxy and certificate, and
not evidence that the app is broken against self-hosted installations generally.

##### The push relay is a privacy decision

Push notifications work on a self-hosted installation, free, through Chatwoot's
relay at `hub.2.chatwoot.com`. Message bodies cross that relay, because a push
notification carries a preview of the message.

```
ENABLE_PUSH_RELAY_SERVER=true
```

Setting it to `false` does not give you private push. It gives you no push.
Private push means building and shipping your own mobile app, which needs
Firebase credentials plus an Apple developer account ($99 a year) and a Google
Play account ($25).

For one operator answering their own queue, the relay is almost certainly the
right trade. It is still a decision about where your visitors' first lines of
text travel, so make it on purpose and write it down, rather than arriving at it
by leaving a default alone. If those opening messages routinely contain things
you would not send to a third party, the answer changes, and the cost of the
custom build is the price of that answer.

Three further decisions belong in the same note, because a later reader will
otherwise assume none of them was considered: how many people answer
conversations, what the widget is allowed to cost you, and what to do about the
second CVE. The rules they sit under are in
[The eleven rules](../SKILL.md#the-eleven-rules).
