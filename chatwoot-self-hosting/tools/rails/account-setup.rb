# Applies the account-wide settings, after onboarding has created the operator.
# Safe to run again: it writes only what differs.
#
#   docker compose exec -T -e SUPPORT_EMAIL="Support <no-reply@mail.example.com>" \
#     rails bundle exec rails runner - < account-setup.rb
#
# Assumes one account. See hardening.md, "the single-operator model", for what
# to change when more than one person answers conversations.

abort 'no account yet: complete /installation/onboarding first' if Account.count.zero?
abort "expected exactly one account, found #{Account.count}" unless Account.count == 1

account = Account.first

# Per-inbox unread badges in the sidebar. The feature ships off.
account.enable_features!('conversation_unread_counts')

# The address visitor transcript emails come from. It is account-wide: a widget
# inbox cannot have its own.
support_email = ENV.fetch('SUPPORT_EMAIL')
account.update!(support_email: support_email) unless account.support_email == support_email

puts "account         : #{account.name} (id #{account.id})"
puts "support email   : #{account.support_email}"
puts "unread counts   : #{account.feature_enabled?('conversation_unread_counts')}"
