#
# A quick manual look at Fugit.cron_relation.
#
# Run with:
#   bundle exec ruby tst/cron_relation.rb
#

require 'fugit'

def show(a, b, from='2024-03-01 10:00:00 UTC')

  r = Fugit.cron_relation(a, b, from)

  puts
  puts "  #{a}"
  puts "  #{b}   (from #{from[0, 10]})"
  print "  => #{r.relation}"
  print " (#{r.reason})" if r.undecidable?
  print " witness: #{r.witness.strftime('%F %T %z')} (only #{r.side} fires)" \
    if r.witness
  puts
end

puts 'equal / directed containment / intersection / disjoint'

show('0 0 * * *',     '0 0 * * *')
show('0 0 1,15 * 5',  '0 0 * * 5')
show('0 0 * * 5',     '0 0 1,15 * 5')
show('0 0 L 2 *',     '0 0 28 2 *')
show('0 0 29 2 *',    '0 0 28 2 *')

puts
puts 'the witness is the earliest distinguishing instant at/after "from"'

show('0 0 29 2 *', '0 0 28 2 *', '2023-06-01 UTC')
show('0 0 29 2 *', '0 0 28 2 *', '2096-03-01 UTC') # 2100 is NOT a leap year

puts
puts 'a leap-only difference: "the 29th of February" vs "the last day of February"'
puts 'agree on every common year, diverge ONLY in leap years'

show('0 0 29 2 *', '0 0 L 2 *', '2001-01-01 UTC') # witness: 2001-02-28
show('0 0 29 2 *', '0 0 L 2 *', '2004-01-01 UTC') # shared: 2004-02-29

puts
puts 'undecidable inputs are reported, never guessed'

show('0 0 * * mon%2',       '0 0 * * mon')
show('0 0 1~5 * *',         '0 0 1 * *')
show('0 0 * * * America/New_York', '0 0 * * *')
