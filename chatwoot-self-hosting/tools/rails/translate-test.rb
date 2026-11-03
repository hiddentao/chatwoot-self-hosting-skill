# Tests the automatic translation add-on (auto_translate.rb) on the release it
# runs on. Run it in an upgrade rehearsal stack, against a copy of the database,
# before production changes:
#
#   docker compose exec -T -e TRANSLATE_TEST=1 rails bundle exec rails runner - < translate-test.rb
#
# Google is replaced inside this process by a stand-in, so the test needs no key
# and sends nothing to Google. Visitor messages go through Chatwoot's own
# HookJob, run inline here because a rehearsal stack has no Sidekiq. Replies
# are saved the way the API saves them, which runs the same callbacks.
#
# It creates a throwaway account, so it refuses to run unless TRANSLATE_TEST=1.

abort 'refusing to run: set TRANSLATE_TEST=1 (rehearsal stack only)' unless ENV['TRANSLATE_TEST'] == '1'
abort 'FAIL the add-on is not loaded (its folder is not mounted into config/initializers)' unless defined?(AutoTranslate)

# --- Stand-in for Google -----------------------------------------------------

module StandIn
  GERMAN = /\b(ich|und|das|nicht|mit|ein|eine|geht|auf|jeden|fall|möchte|danke|bitte|hallo)\b/i
  Translation = Struct.new(:translated_text, :detected_language_code)
  Response = Struct.new(:translations)
  Detection = Struct.new(:languages)
  Language = Struct.new(:language_code)

  def self.calls
    @calls ||= []
  end

  class Client
    def translate_text(contents:, target_language_code:, parent:, mime_type:)
      text = contents.first
      StandIn.calls << text
      # Google's sign-in code rescues StandardError and retries. A time limit
      # that raises a StandardError is swallowed by it, and the reply hangs
      # until Chatwoot's 15-second request limit drops it.
      if text.include?('HANG')
        begin
          sleep 60
        rescue StandardError
          retry
        end
      end
      raise ::Google::Cloud::UnavailableError, 'stand-in outage' if text.include?('OUTAGE')

      detected = text.match?(GERMAN) ? 'de' : 'en'
      target = target_language_code.split('-').first
      Response.new([Translation.new(detected == target ? text : "[#{target}] #{text}", detected)])
    end

    def detect_language(content:, parent:)
      Detection.new([Language.new(content.match?(GERMAN) ? 'de' : 'en')])
    end
  end
end

# The add-on's configuration block runs against the real configuration object,
# so a setting the release no longer has fails here.
Google::Cloud::Translate::V3::TranslationService::Client.singleton_class.prepend(Module.new do
  def new(*, &block)
    block&.call(::Google::Cloud::Translate::V3::TranslationService::Client::Configuration.new(configure))
    StandIn::Client.new
  end
end)

# --- Fixture -----------------------------------------------------------------

stamp = SecureRandom.hex(4)
account = Account.create!(name: "translate-test-#{stamp}", locale: 'en')
operator = User.create!(name: 'Translate test', email: "translate-test-#{stamp}@example.invalid",
                        password: "#{SecureRandom.hex(12)}aA1!", confirmed_at: Time.current,
                        ui_settings: { 'locale' => 'en' })
AccountUser.create!(account: account, user: operator, role: :administrator)
channel = Channel::WebWidget.create!(account: account, website_url: 'https://example.invalid')
inbox = Inbox.create!(account: account, channel: channel, name: "translate-test-#{stamp}")
hook = Integrations::Hook.create!(account: account, app_id: 'google_translate', status: :enabled,
                                  settings: { 'project_id' => 'stand-in', 'credentials' => { 'stand_in' => true } })

new_conversation = lambda do
  contact = Contact.create!(account: account, name: 'Visitor')
  contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
  Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
end

visitor_says = lambda do |conversation, text|
  message = conversation.messages.create!(account: account, inbox: inbox, message_type: :incoming,
                                          sender: conversation.contact, content: text)
  HookJob.perform_now(hook, 'message.created', message: message)
  message.reload
end

operator_says = lambda do |conversation, text, private: false|
  conversation.messages.create!(account: account, inbox: inbox, message_type: :outgoing, sender: operator,
                                content: text, private: private).reload
end

language_of = ->(conversation) { conversation.reload.additional_attributes['conversation_language'] }
failure_notice = lambda do |conversation, after|
  conversation.messages.activity.where('id > ?', after.id).where('content LIKE ?', 'Automatic translation failed%').exists?
end

# --- Checks ------------------------------------------------------------------

checks = {}
AutoTranslate.problems.each { |problem| checks["self-check: #{problem}"] = false }
checks['self-check finds nothing missing'] = AutoTranslate.problems.empty?

german = new_conversation.call
incoming = visitor_says.call(german, 'Ich möchte ein ebook und eine eigene Website erstellen')
checks['a German visitor message gets an English translation'] =
  incoming.translations&.dig('en') == '[en] Ich möchte ein ebook und eine eigene Website erstellen'
checks['the conversation records German as the visitor language'] = language_of.call(german) == 'de'

reply = operator_says.call(german, 'Yes, we can do that.')
checks['an English reply is sent in German'] = reply.content == '[de] Yes, we can do that.'
checks['the English reply is kept for the operator'] = reply.translations&.dig('en') == 'Yes, we can do that.'
checks['webhooks and search get the German text'] = reply.processed_message_content == reply.content

reply = operator_says.call(german, 'Das geht auf jeden Fall.')
checks['a reply already in German is sent as typed'] =
  reply.content == 'Das geht auf jeden Fall.' && reply.translations.blank?

calls_before = StandIn.calls.size
note = operator_says.call(german, 'Internal: check pricing first', private: true)
checks['a private note is left alone, with no call to Google'] =
  note.content == 'Internal: check pricing first' && StandIn.calls.size == calls_before

visitor_says.call(german, 'ok')
checks['a short message does not change the visitor language'] = language_of.call(german) == 'de'

english = new_conversation.call
incoming = visitor_says.call(english, 'Hello, can I make an ebook here?')
checks['an English visitor message is left alone'] = incoming.translations.blank?
calls_before = StandIn.calls.size
reply = operator_says.call(english, 'Sure, we can do that.')
checks['a reply to an English visitor is sent as typed, with no call to Google'] =
  reply.content == 'Sure, we can do that.' && StandIn.calls.size == calls_before

reply = operator_says.call(german, 'This reply meets an OUTAGE')
checks['when Google fails, the reply is sent as typed'] = reply.content == 'This reply meets an OUTAGE'
checks['when Google fails, a system line tells the operator'] = failure_notice.call(german, reply)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
reply = operator_says.call(german, 'This reply meets a HANG')
waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
checks["when Google never answers, the reply is sent as typed within 10 seconds (#{waited.round(1)}s)"] =
  reply.content == 'This reply meets a HANG' && waited < 10
checks['when Google never answers, a system line tells the operator'] = failure_notice.call(german, reply)

hook.update!(status: :disabled)
calls_before = StandIn.calls.size
quiet = new_conversation.call
incoming = visitor_says.call(quiet, 'Hallo, ich brauche bitte Hilfe')
quiet.update!(additional_attributes: { 'conversation_language' => 'de' })
reply = operator_says.call(quiet, 'Happy to help.')
checks['with the integration disconnected, nothing is translated or sent to Google'] =
  incoming.translations.blank? && reply.content == 'Happy to help.' && StandIn.calls.size == calls_before

checks.each { |name, passed| puts "  #{passed ? 'ok  ' : 'FAIL'} #{name}" }
exit(checks.values.all? ? 0 : 1)
