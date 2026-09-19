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
#
# Compare the stored column, not the reader. Account#support_email falls back to
# MAILER_SENDER_EMAIL when the column is null, so an operator who uses the same
# address for both would satisfy a reader comparison with an unwritten column,
# and transcript mail would then follow operator mail for ever after.
support_email = ENV.fetch('SUPPORT_EMAIL')
stored = account.attributes['support_email']
account.update!(support_email: support_email) unless stored == support_email
account.reload

puts "account         : #{account.name} (id #{account.id})"
puts "support email   : #{account.attributes['support_email'].inspect} stored"
puts "                  #{account.support_email} effective"
puts "unread counts   : #{account.feature_enabled?('conversation_unread_counts')}"
