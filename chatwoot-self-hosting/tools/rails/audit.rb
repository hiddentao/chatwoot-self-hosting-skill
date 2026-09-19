# Checks the hardening rules that live in the database, rather than in the
# environment. Exits non-zero when any rule is broken.
#
#   docker compose exec -T rails bundle exec rails runner - < audit.rb
#
# Two checks encode the single-operator model: exactly one user, and exactly one
# account membership. A team installation replaces those two counts with its own
# and keeps the other ten unchanged. In particular keep the platform-app and MFA
# assertions as they are: those are not about headcount.
# See hardening.md, "the single-operator model".

checks = {
  'account signup is disabled in the database' =>
    InstallationConfig.find_by(name: 'ENABLE_ACCOUNT_SIGNUP')&.value.to_s == 'false' &&
    !GlobalConfigService.account_signup_enabled?,
  'installation onboarding is closed' =>
    Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING).blank?,
  'no platform apps exist' => PlatformApp.none?,
  'exactly one user exists' => User.count == 1,
  'exactly one account membership exists' => AccountUser.count == 1,
  'every user has MFA turned on' => User.where(otp_required_for_login: false).none?,
  'MFA encryption keys are configured' => Chatwoot.mfa_enabled?,
  'no API-channel inboxes exist' => Channel::Api.none?,
  'no help-centre portals exist' => Portal.none?,
  'every account shows unread counts' =>
    Account.all.all? { |account| account.feature_enabled?('conversation_unread_counts') },
  'every widget inbox restricts framing' =>
    Channel::WebWidget.all.all? { |widget| widget.allowed_domains.present? },
  'every widget inbox requires signed identities' =>
    Channel::WebWidget.all.all?(&:hmac_mandatory)
}

checks.each { |name, passed| puts "  #{passed ? 'ok  ' : 'FAIL'} #{name}" }
exit(checks.values.all? ? 0 : 1)
