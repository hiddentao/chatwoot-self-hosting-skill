# Gives one inbox a rule that assigns every new conversation to the operator.
#
#   docker compose exec -T -e INBOX_NAME=Example \
#     rails bundle exec rails runner - < auto-assign.rb
#
# The inbox setting named auto assignment is round-robin, and it draws only from
# agents the presence tracker currently reports as online. A queue answered by
# one person therefore leaves conversations unassigned for exactly the hours
# nobody is watching the dashboard. A rule carries no such condition.
#
# Assumes one account and one operator. See hardening.md, "the single-operator
# model", for the team version of this rule.

abort 'expected exactly one account' unless Account.count == 1

account = Account.first
name = ENV.fetch('INBOX_NAME')
inbox = account.inboxes.find_by('lower(name) = ?', name.downcase)
abort "no inbox named #{name}" if inbox.nil?

abort "expected exactly one operator, found #{account.users.count}" unless account.users.count == 1

agent = account.users.first
rule_name = "Assign #{inbox.name} to the operator"

rule = ActiveRecord::Base.transaction do
  record = account.automation_rules.find_or_initialize_by(name: rule_name)
  record.update!(
    description: "Every new #{inbox.name} conversation goes to #{agent.name}.",
    event_name: 'conversation_created',
    active: true,
    conditions: [
      {
        attribute_key: 'inbox_id',
        filter_operator: 'equal_to',
        values: [inbox.id],
        query_operator: nil
      }
    ],
    actions: [{ action_name: 'assign_agent', action_params: [agent.id] }]
  )
  record
end

# The rule answers new conversations. Anything already waiting predates it, and
# is read into an array first, because the query that finds them stops matching
# them as they are assigned.
waiting = inbox.conversations.where(assignee_id: nil).to_a
waiting.each { |conversation| conversation.update!(assignee: agent) }

puts "rule            : #{rule.name} (id #{rule.id})"
puts "event           : #{rule.event_name}"
puts "inbox           : #{inbox.name} (id #{inbox.id})"
puts "assignee        : #{agent.name} <#{agent.email}>"
puts "already waiting : #{waiting.size} assigned now"
