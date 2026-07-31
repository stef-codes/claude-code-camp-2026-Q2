# Deliberately empty, and committed rather than generated.
#
# This app owns no tables. Every view reads someone else's storage — the agent's
# knowledge.sqlite3 through Knowledge::Reader, its jsonl logs through the
# SessionLog/TelnetLog/ManagerLog/Journal POROs, and the parsed CircleMUD world
# through World::Atlas — and there is not one ActiveRecord model or migration in
# the tree. `storage/development.sqlite3` exists because Rails insists on a
# connection, not because anything is stored in it.
#
# It has to exist anyway because of test parallelisation. `test_helper.rb` calls
# `parallelize(workers: :number_of_processors)`, and each forked worker runs
# `db:test:prepare`, which loads this file. Without it every worker aborts with
#
#   db/schema.rb doesn't exist yet. Run `bin/rails db:migrate` to create it
#
# and the run hangs with no failing test and no useful output. That only shows
# up once a selection exceeds the 50-test parallelisation threshold, so single
# files pass happily and `bin/rails test` — the documented command — hangs
# forever. Verified on a clean checkout with no other changes.
#
# `version: 0` says there are no migrations to be behind on. If this app ever
# gains a table of its own, that will be the moment to run `db:migrate` and let
# it overwrite this file.
ActiveRecord::Schema[8.1].define(version: 0) do
end
