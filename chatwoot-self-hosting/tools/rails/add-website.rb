# Creates or updates one website (widget) inbox with the hardened settings.
#
#   docker compose exec -T \
#     -e INBOX_NAME=Example -e WEBSITE_URL=https://example.com \
#     -e ALLOWED_DOMAINS="https://example.com, https://*.example.com" \
#     -e BUSINESS_NAME=Example \
#     rails bundle exec rails runner - < add-website.rb
#
# ALLOWED_DOMAINS must not be blank. A blank value removes the framing
# restriction rather than defaulting closed, so any site could embed the widget.
#
# Assumes one account. See hardening.md, "the single-operator model".

abort 'expected exactly one account' unless Account.count == 1

account = Account.first
name = ENV.fetch('INBOX_NAME')
allowed_domains = ENV.fetch('ALLOWED_DOMAINS')
abort 'ALLOWED_DOMAINS must not be blank' if allowed_domains.strip.empty?

channel_attributes = {
  website_url: ENV.fetch('WEBSITE_URL'),
  allowed_domains: allowed_domains,
  hmac_mandatory: true,
  pre_chat_form_enabled: false
}

inbox = ActiveRecord::Base.transaction do
  # Matched without case, so an inbox renamed in the dashboard is updated rather
  # than duplicated.
  existing = account.inboxes.find_by('lower(name) = ?', name.downcase)
  if existing
    abort "inbox #{name} exists and is not a website inbox" unless existing.web_widget?
    existing.channel.update!(channel_attributes)
    existing.update!(business_name: ENV.fetch('BUSINESS_NAME'))
    existing
  else
    channel = account.web_widgets.create!(channel_attributes)
    account.inboxes.create!(name: name, channel: channel, business_name: ENV.fetch('BUSINESS_NAME'))
  end.tap do |record|
    # The operator is a member of every inbox, so new conversations notify them.
    account.users.each { |user| InboxMember.find_or_create_by!(inbox: record, user: user) }
  end
end

channel = inbox.channel
puts "inbox           : #{inbox.name} (id #{inbox.id})"
puts "allowed domains : #{channel.allowed_domains}"
puts "hmac mandatory  : #{channel.hmac_mandatory}"
puts "website token   : #{channel.website_token}   (public)"
puts 'hmac token      : set; read it from Settings > Inboxes > (inbox) > Configuration'
