# Issues a fresh HMAC token for a website inbox. The value is never printed:
# read it from the dashboard, Settings > Inboxes > (inbox) > Configuration.
#
#   docker compose exec -T -e INBOX_NAME=Example \
#     rails bundle exec rails runner - < rotate-hmac.rb
#
# Every place that signs identities needs the new value before signed visitors
# work again. Rotate, collect the new token, then deploy it everywhere at once.

inbox = Account.first.inboxes.find_by!('lower(name) = ?', ENV.fetch('INBOX_NAME').downcase)
channel = inbox.channel
before = channel.hmac_token
channel.regenerate_hmac_token
channel.reload
puts "inbox          : #{inbox.name}"
puts "hmac token     : rotated (#{before[0, 3]}... -> #{channel.hmac_token[0, 3]}...), same length #{channel.hmac_token.length}"
puts "website token  : #{channel.website_token} (unchanged, public)"
