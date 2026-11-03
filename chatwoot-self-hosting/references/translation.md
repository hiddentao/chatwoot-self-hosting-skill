# Automatic translation, in both directions

A visitor writes in their language. The operator reads it in theirs and answers
in theirs, and the visitor reads the answer in their own. Chatwoot translates
one message at a time when someone asks it to; a small Rails add-on on the
stock image makes it automatic in both directions.

Everything here was read in Chatwoot 4.17.1, at the commit the `v4.17.1` tag
points to (`b354a9550e1fb59fa537a9c384232cb076213e72`), and the mobile app at
commit `16d6828d59da9d21ca7a2fac757e711670c60dbb`. The add-on and its test were
run against the `v4.17.1-ce` image.

#### What the release gives you

| Piece | What it does | Where |
| --- | --- | --- |
| Translate one message | The dashboard's message menu and the mobile app's long-press action call `POST .../messages/:id/translate`. It uses the Google Translate integration only, and stores the result in `content_attributes.translations[locale]`. | `app/controllers/api/v1/accounts/conversations/messages_controller.rb#translate` |
| Detect the visitor's language | With the integration connected, `HookJob` runs `DetectLanguageService` on `message.created`. It sets `conversation_language` once, from the first incoming message. | `app/jobs/hook_job.rb`, `lib/integrations/google_translate/` |
| Show a translation | When `translations` holds a value, the dashboard and the mobile app show it in place of `content`, with a **View original** link. | `components-next/message/bubbles/Text/Index.vue`; `TextBubble.tsx` in the mobile app |
| Translate a reply | Nothing does. The editor's AI actions are `fix_spelling_grammar`, `improve` and five tones. The AI reply suggestion writes in the customer's language, but writes its own reply. | `lib/captain/rewrite_service.rb`, `lib/integrations/openai/openai_prompts/reply.liquid` |

The widget renders `content` and never reads `translations`. A reply therefore
has to be translated before it is saved, and an incoming message only needs a
translation stored beside it.

#### The add-on

`tools/initializers/auto_translate.rb` is one Ruby file. Rails loads every file
under `config/initializers`, sub-folders included, so the compose templates
mount a folder there for both Rails and Sidekiq:

```
- ./initializers:/app/config/initializers/local:ro
```

It attaches in two places, once, from a `to_prepare` block:

| Direction | Attached to | Runs in | Result |
| --- | --- | --- | --- |
| Visitor to operator | `HookJob#google_translate_integration`, wrapped with `prepend` | Sidekiq, a moment after the message arrives | a translation into the account's language in `translations` |
| Operator to visitor | a `before_save` on new messages, placed first | the request that creates the reply | `content` in the visitor's language, the typed text in `translations` |

The outgoing callback has to be first. `ensure_processed_message_content`, also
a `before_save`, copies `content` into `processed_message_content`, which
webhooks and the Slack integration send. Running after it would send the
operator's language there and the visitor's language everywhere else.

The rules it applies:

- **The visitor's language** is what Google detects in their messages, stored
  as `conversation_language`. It follows their latest message of at least 20
  characters, so "ok" does not change it. Until the visitor writes, it is
  unknown and replies go out as typed.
- **The operator's language** is the `locale` in their UI settings, or the
  account's locale. Incoming messages are translated into the account's locale.
- **A reply is translated** only when the two languages differ, and only when
  Google does not detect the visitor's language in it already. The same call
  translates and detects, so this costs nothing extra.
- **Only text from people.** Private notes, bot, automation and campaign
  messages, non-text content types and email inboxes are left alone.
- **A failure sends the reply as typed**, and adds an activity message saying
  so. Activity messages never reach the visitor: `ActionCableListener` skips
  them for contacts, and the widget's message list filters them out.

`AutoTranslate.problems` returns every upstream piece the file relies on that
the running release lacks: the hook route, the wrapped method, the
`translations` accessor, the `processed_message_content` column, the account
locale and the Google client's detected-language field. Empty means the file
fits.

#### Installing it

1. Copy `tools/initializers/` to `initializers/` beside `compose.yaml` on the
   host.
2. In Google Cloud, use a project that does nothing else. Turn billing on;
   Cloud Translation requires it. Enable the Cloud Translation API
   (`translate.googleapis.com`). Create a service account whose only role is
   Cloud Translation API User (`roles/cloudtranslate.user`), and a JSON key for
   it. Set a budget alert: by default there is no daily character limit.
3. In the dashboard, open **Settings > Integrations > Google Translate**, press
   **Connect**, fill **Google Cloud Project ID**, paste the whole key file into
   **Google Cloud Project Key File**, and press **Create**. The form parses the
   key as JSON. Delete the downloaded file.
4. Recreate Rails and Sidekiq so they load the file: `docker compose up -d`
   picks up a new mount, and `docker compose restart rails sidekiq` picks up a
   changed file under an existing one.
5. Confirm it loaded and fits:

   ```
   echo 'p AutoTranslate.problems' | \
     docker compose exec -T rails bundle exec rails runner -    # prints []
   ```

   To keep that true, add one entry to `tools/rails/audit.rb`:
   `'the translation add-on fits this release' => defined?(AutoTranslate) &&
   AutoTranslate.problems.empty?`. The shipped audit leaves it out, because the
   add-on is optional.
6. Write a test message in another language from a page with the widget, and
   reply to it.

To turn translation off, disconnect the integration. Both directions stop, the
translations already stored stay, and the add-on stays loaded and idle.

#### The time limit

A reply waits for Google, and three limits meet there.

| Limit | Value at 4.17.1 | Source |
| --- | --- | --- |
| Chatwoot ends a request | 15 seconds | `rack-timeout` 0.6.3, `RACK_TIMEOUT_SERVICE_TIMEOUT` unset; it raises outside `StandardError` |
| The Google client waits for `translate_text` | 600 seconds | `google-cloud-translate-v3` 0.10.0, `client.rb` defaults |
| The add-on waits for Google | 8 seconds | `AutoTranslate::TIMEOUT_SECONDS` |

The client's own limit covers the RPC and not the OAuth token fetch before it.
With Google accepting connections and never answering, a reply returned HTTP
500 after 15.0 seconds and was not saved. The add-on wraps the whole call in
`Timeout.timeout(8)` with no error class. Ruby then interrupts with an
exception outside `StandardError`, which the sign-in code's `rescue` and retry
cannot catch, and converts it to `Timeout::Error` at the boundary. Measured on
the same silent endpoint: the reply went out as typed after 8.3 and 8.1 seconds
in two runs, with the activity message. Passing an error class to
`Timeout.timeout` makes the interrupt a `StandardError`, which the retry
swallows; the reply then failed at 15 seconds again. Keep the add-on's limit
below `RACK_TIMEOUT_SERVICE_TIMEOUT` if you change that variable.

After any failure the add-on drops its cached client, so the next call builds a
fresh one.

#### The widget's language

The widget sends its interface language as `locale` with every request
(`widget/helpers/urlParamsHelper.js`). The two email-collect prompts, "Give the
team a way to reach you" and "Get notified by email", are built with `I18n.t`
in that locale. A fixed `locale: 'en'` in `chatwootSettings` therefore gives
every visitor English prompts, whatever they write.

`useBrowserLanguage: true` takes the browser's language instead
(`entrypoints/sdk.js`). The widget maps `de_DE` to `de`, and keeps its default
for a language it does not ship (`widget/App.vue#setLocale`). Measured: a
conversation created with `locale=de` received both prompts in German.

#### Upgrades

The add-on depends on code a release can move without notice, so every upgrade
rehearsal runs its test, `tools/rails/translate-test.rb`, in the rehearsal
container with the new image:

```
docker compose -p chatwoot-staging -f compose.staging.yaml \
  exec -T -e TRANSLATE_TEST=1 rails bundle exec rails runner - \
  < tools/rails/translate-test.rb
```

It replaces Google with a stand-in inside the runner process, so it needs no
key and sends nothing out. It runs the self-check and sixteen behaviours, among
them a Google that never answers, and exits non-zero on any failure. It creates
a throwaway account, so it refuses to run without `TRANSLATE_TEST=1`; run it
only against the rehearsal copy. See
[upgrades](upgrades.md#what-to-assert-before-believing-it-passed).

No script can see the apps. After an upgrade, open a translated message in the
dashboard and in the mobile app and confirm **View original** is still there.

#### Cost, privacy and limits

Google charges per character sent. That is every visitor text message, since
Google must read a message to learn its language, and every reply to a visitor
whose language differs. Detection during a translate call is not charged
separately. On the pricing page read on 2026-11-03, the first 500,000
characters a month were free and further characters cost $20 per million.

- **Text leaves the installation.** While the integration is connected, visitor
  messages and translated replies go to Google. Decide that the way you decide
  the push relay.
- **The key is stored in plain text.** Integration settings are a plain `jsonb`
  column, `integrations_hooks.settings`; only `access_token` is encrypted
  (`app/models/integrations/hook.rb`). Keep the key's role and project narrow.
- **The visitor's browser receives both texts.** The widget gets the message
  record with `content_attributes`, so the operator's typed text and the
  translation of the visitor's own message reach it, unshown.
- **The conversation list shows `content`.** The operator's last reply appears
  there in the visitor's language, and push notifications show the visitor's
  original text.
- **Formatting travels as plain text.** Check a reply that depends on it.
