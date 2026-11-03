# frozen_string_literal: true

# Automatic translation of conversations, in both directions.
#
# Compose mounts this folder into config/initializers, so Rails loads the file at
# start-up in both the rails and the sidekiq containers. It changes no Chatwoot
# file and needs no custom image.
#
# Visitor to operator: Sidekiq translates every incoming text message into the
# account's language and stores the result in the message's `translations`. The
# dashboard and the mobile app show a stored translation first, with a link to
# the original.
#
# Operator to visitor: a reply that a person types is translated into the
# visitor's language before Chatwoot saves it, so every channel sends the
# translated text. The typed text is kept in `translations` under the operator's
# language, so the operator goes on reading their own words.
#
# Both directions use the account's Google Translate integration
# (Settings > Integrations > Google Translate). Disconnect it to turn both off.
#
# Checked against Chatwoot 4.17.1. `AutoTranslate.problems` lists every upstream
# behaviour this file depends on that is missing; the audit and the upgrade
# rehearsal run it.
require 'google/cloud/translate/v3'

module AutoTranslate
  APP_ID = 'google_translate'

  # A reply waits on Google, and Chatwoot ends any request after 15 seconds
  # (rack-timeout), which would drop the reply. The client library's own limit
  # (600 seconds by default) covers only the translation call, not the sign-in
  # that comes before it, so one limit wraps both.
  TIMEOUT_SECONDS = 8

  class TimeoutError < StandardError; end

  # Detection on a short message such as "ok" or "danke" is a guess. Only a
  # message at least this long may change the language already stored on the
  # conversation.
  MIN_LANGUAGE_SAMPLE = 20

  Result = Struct.new(:text, :detected_language, keyword_init: true)

  CLIENTS = {}
  CLIENTS_LOCK = Mutex.new

  module_function

  # --- Visitor to operator (runs in Sidekiq) -----------------------------------

  def translate_incoming(hook, message)
    return unless incoming_candidate?(message)

    target = message.account.locale.to_s
    return if message.translations.is_a?(Hash) && message.translations[target].present?

    result = translate(hook, message.content, target)
    return if result.nil?

    remember_visitor_language(message, result.detected_language)
    return if result.detected_language.present? && same_language?(result.detected_language, target)
    return if result.text.blank? || result.text == message.content

    message.update!(translations: existing_translations(message).merge(target => result.text))
  rescue StandardError => e
    log_failure('incoming', message, e)
  end

  def incoming_candidate?(message)
    message.present? && message.incoming? && !message.private? &&
      message.content.present? && message.content_type == 'text' && !message.inbox.email?
  end

  # The conversation's `conversation_language` is what replies are translated
  # into. It follows the visitor's latest message that is long enough to judge.
  def remember_visitor_language(message, language)
    return if language.blank?

    conversation = message.conversation
    attributes = conversation.additional_attributes || {}
    current = attributes['conversation_language']
    return if current == language
    return if current.present? && message.content.length < MIN_LANGUAGE_SAMPLE

    conversation.update!(additional_attributes: attributes.merge('conversation_language' => language))
  end

  # --- Operator to visitor (runs in the request that creates the reply) ---------

  def translate_outgoing(message)
    return unless outgoing_candidate?(message)

    hook = enabled_hook(message.account)
    return if hook.nil?

    visitor_language = message.conversation.additional_attributes&.dig('conversation_language')
    return if visitor_language.blank?

    operator_language = operator_language(message)
    return if same_language?(visitor_language, operator_language)

    result = translate(hook, message.content, visitor_language)
    raise 'Google returned no translation' if result.nil?
    # The operator wrote in the visitor's language already.
    return if result.detected_language.present? && same_language?(result.detected_language, visitor_language)
    return if result.text.blank? || result.text == message.content

    message.translations = existing_translations(message).merge(operator_language => message.content)
    message.content = result.text
  rescue StandardError => e
    log_failure('outgoing', message, e)
    message.auto_translate_failure = failure_reason(e)
  end

  def outgoing_candidate?(message)
    message.outgoing? && !message.private? && message.sender.is_a?(User) &&
      message.content.present? && message.content_type == 'text' &&
      message.translations.blank? && !message.inbox.email? &&
      message.content_attributes['automation_rule_id'].blank? &&
      (message.additional_attributes || {})['campaign_id'].blank?
  end

  # The key the operator's own dashboard looks up first.
  def operator_language(message)
    message.sender.ui_settings&.dig('locale').presence || message.account.locale.to_s
  end

  # A system line in the conversation, which the visitor never receives, so the
  # operator learns that the reply went out as typed.
  def report_failure(message)
    message.conversation.messages.create!(
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      message_type: :activity,
      content: "Automatic translation failed, so the reply above was sent as typed (#{message.auto_translate_failure})."
    )
  rescue StandardError => e
    log_failure('failure notice', message, e)
  end

  # --- Google --------------------------------------------------------------------

  def enabled_hook(account)
    hook = account.hooks.find_by(app_id: APP_ID)
    hook if hook&.enabled?
  end

  # One request both translates and reports the language Google detected.
  def translate(hook, text, target)
    # No error class is passed on purpose: Timeout then interrupts with an
    # exception that the sign-in code's own `rescue StandardError` and retry
    # cannot catch, and turns it into Timeout::Error only out here.
    response = Timeout.timeout(TIMEOUT_SECONDS) do
      client(hook).translate_text(
        contents: [text],
        target_language_code: target.to_s.tr('_', '-'),
        parent: "projects/#{hook.settings['project_id']}",
        mime_type: 'text/plain'
      )
    end
    translation = response.translations.first
    return if translation.nil?

    Result.new(text: translation.translated_text, detected_language: translation.detected_language_code.presence)
  rescue Timeout::Error
    forget_client(hook)
    raise TimeoutError, "Google did not answer within #{TIMEOUT_SECONDS} seconds"
  rescue StandardError
    # A call cut off part-way may leave the client unusable; start afresh.
    forget_client(hook)
    raise
  end

  # Building a client parses the key and opens a channel, so keep one per
  # process, and build a new one when the integration's settings change.
  def client(hook)
    key = [hook.id, hook.updated_at.to_f]
    CLIENTS_LOCK.synchronize do
      CLIENTS.delete_if { |cached_key, _| cached_key.first == hook.id && cached_key != key }
      CLIENTS[key] ||= ::Google::Cloud::Translate::V3::TranslationService::Client.new do |config|
        config.credentials = hook.settings['credentials']
        config.rpcs.translate_text.timeout = TIMEOUT_SECONDS
      end
    end
  end

  def forget_client(hook)
    CLIENTS_LOCK.synchronize { CLIENTS.delete_if { |cached_key, _| cached_key.first == hook.id } }
  end

  # --- Helpers -------------------------------------------------------------------

  def same_language?(one, other)
    base_language(one) == base_language(other)
  end

  def base_language(code)
    code.to_s.downcase.split(/[-_]/).first
  end

  def existing_translations(message)
    message.translations.is_a?(Hash) ? message.translations : {}
  end

  def failure_reason(error)
    reason = error.respond_to?(:details) ? error.details.presence : nil
    (reason || error.message.presence || error.class.name).to_s.squish.truncate(200)
  end

  def log_failure(direction, message, error)
    Rails.logger.warn(
      "[auto-translate] #{direction} message #{message&.id || '(new)'} in conversation " \
      "#{message&.conversation_id.inspect} not translated: #{error.class}: #{error.message.to_s.squish.truncate(300)}"
    )
  end

  # --- Attachment to Chatwoot ----------------------------------------------------

  # Wraps the job Chatwoot already runs for the Google Translate integration on
  # every new message. Translating first also stores the visitor's language, so
  # Chatwoot's own detection call that follows has nothing left to do.
  module HookJobExtension
    private

    def google_translate_integration(hook, event_name, event_data)
      AutoTranslate.translate_incoming(hook, event_data[:message]) if event_name == 'message.created'
      super
    end
  end

  module MessageCallbacks
    extend ActiveSupport::Concern

    included do
      attr_accessor :auto_translate_failure

      # First of the save callbacks, so the copy of the text that Chatwoot keeps
      # for webhooks and search (`processed_message_content`) is the translation.
      before_save :auto_translate_outgoing, prepend: true, if: :new_record?
      after_create_commit :auto_translate_report_failure, if: :auto_translate_failure
    end

    private

    def auto_translate_outgoing
      AutoTranslate.translate_outgoing(self)
    end

    def auto_translate_report_failure
      AutoTranslate.report_failure(self)
    end
  end

  def attach!
    HookJob.prepend(HookJobExtension) unless HookJob.ancestors.include?(HookJobExtension)
    Message.include(MessageCallbacks) unless Message.include?(MessageCallbacks)
  end

  # Every upstream behaviour this file relies on, as a list of what is missing.
  # Empty means the file fits the running release.
  def problems
    list = []
    list << 'the add-on is not attached to HookJob' unless HookJob.ancestors.include?(HookJobExtension)
    list << 'the add-on is not attached to Message' unless Message.include?(MessageCallbacks)
    unless HookJob::INTEGRATION_PROCESSORS[APP_ID] == :google_translate_integration
      list << 'HookJob no longer routes Google Translate events to google_translate_integration'
    end
    unless HookJob.instance_method(:google_translate_integration).super_method
      list << 'HookJob#google_translate_integration no longer exists'
    end
    probe = Integrations::Hook.new(app_id: APP_ID, status: :enabled)
    unless HookListener.instance.send(:supported_hook_event?, probe, 'message.created')
      list << 'new messages no longer reach the Google Translate integration'
    end
    list << 'Message has no translations attribute' unless Message.method_defined?(:translations=)
    list << 'Message has no processed_message_content column' unless Message.column_names.include?('processed_message_content')
    list << 'Account has no locale column' unless Account.column_names.include?('locale')
    unless defined?(::Google::Cloud::Translate::V3::Translation) &&
           ::Google::Cloud::Translate::V3::Translation.descriptor.lookup('detected_language_code')
      list << 'the Google Cloud Translation client is missing, or no longer reports the detected language'
    end
    list
  end
end

Rails.application.config.to_prepare { AutoTranslate.attach! }
