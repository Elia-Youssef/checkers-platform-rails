# Seed data: two demo accounts and one finished demo game, so that a fresh install has
# something to look at on My games, in the replay and in the PDN export (TASK-BRIEF 1.7).
#
#   bin/rails db:seed          load it (bin/rails db:setup and db:reset run it too)
#
# It is idempotent: a second run finds the accounts and the game already there, creates
# nothing and changes nothing.
#
# In production it creates nothing unless DEMO_SEEDS is 1 (see DemoSeeds below).
#
# The game is real. It is not a hand-written list of positions: the two accounts are created,
# an online match is opened and joined through the model's own methods, and the moves below
# are played one leg at a time through Match#play_leg!, the same path a click on the board
# takes. So every stored position is one the engine wrote, the result and the reason are the
# engine's verdict rather than a status set by hand, and an illegal move here stops the seed
# with the engine's own message instead of writing a game that cannot have happened.
#
# Where the move list came from. It is one complete game between the built-in AI at Hard
# (Red) and at Medium (White), generated once inside the container with:
#
#   docker compose run --rm -T web ruby -Ilib -e '
#     require "draughts"
#     game = Draughts::Game.new
#     levels = { Draughts::Side::RED => :hard, Draughts::Side::WHITE => :medium }
#     ply = 0
#     until game.finished? || ply >= 150
#       game.play(Draughts::AI.choose(game, level: levels.fetch(game.side_to_move),
#                                     random: Random.new(7 + ply)).move)
#       ply += 1
#     end
#     puts game.moves.map(&:pdn).join(" ")
#     puts "#{game.plies} plies, #{game.result} by #{game.reason}"'
#
# which printed these 103 plies and "red_won by no_pieces" in 53 seconds. Hard's iterative
# deepening is driven by the wall clock, so re-running that command on another machine can
# produce a different game; this one is frozen here, and the seed proves it legal every time
# it runs.

# Whether the demo data should be created at all, given the environment and the value of
# DEMO_SEEDS. A method rather than an inline condition so that a unit test can ask it directly
# (test/models/seeds_test.rb) without loading a whole environment.
#
# Development and test always want the demo data: a fresh clone should have something to look
# at on My games, and bin/ci loads this file. Production is different. bin/docker-entrypoint
# runs bin/rails db:prepare, which loads this file the first time the image is started against
# an empty volume, so without a guard every production container would come up carrying two
# accounts whose password is published in this repository's README (session-7 audit, finding
# M1). There the demo data is created only when the operator asks for it:
#
#   docker run ... -e DEMO_SEEDS=1 checkers
#
# Surrounding whitespace is ignored, so a value typed with a stray space still counts. Any
# other value, and no value at all, means no demo data.
module DemoSeeds
  def self.wanted?(environment, flag)
    environment.to_s != "production" || flag.to_s.strip == "1"
  end
end

unless DemoSeeds.wanted?(Rails.env, ENV["DEMO_SEEDS"])
  puts "[seeds] production without DEMO_SEEDS=1: no demo accounts and no demo game were " \
       "created. Start the container with -e DEMO_SEEDS=1 to get them."
  return
end

password = "demo-checkers"
accounts = {
  red: { email_address: "demo-red@example.com", display_name: "Demo Red" },
  white: { email_address: "demo-white@example.com", display_name: "Demo White" }
}

# 103 plies, Red (Hard) against White (Medium), ending with White having no pieces left. The
# 29th ply, 3x10x19x26, is a triple jump, and it is one move and one row like any other.
demo_game = %w[
  11-16 23-19 16x23 27x18 12-16 24-19 16x23 26x19
  9-14 18x9 5x14 30-26 8-11 31-27 10-15 19x10
  6x15 27-24 11-16 32-27 1-6 26-23 15-18 22x15
  14-17 21x14 7-10 14x7 3x10x19x26 25-21 16-20 24-19
  6-10 28-24 10-14 29-25 14-18 19-15 4-8 21-17
  26-31 15-10 31-26 17-13 26-30 25-21 8-12 21-17
  30-26 10-6 2x9 13x6 26-22 17-13 12-16 6-1
  18-23 27x18 22x15 13-9 20x27 9-6 27-31 1-5
  31-26 5-1 16-19 1-5 19-24 6-2 15-10 5-9
  26-23 9-5 23-19 5-9 19-15 9-5 15-18 5-1
  18-15 1-5 24-27 5-9 10-6 9-14 6-1 14-17
  27-31 2-7 1-5 7-3 5-9 17-21 31-26 21-25
  15-11 3-8 11x4 25-30 26-22 30-26 22x31
]

# The accounts. find_or_create_by! sets the name and the password only when it creates, so a
# second run leaves an existing account exactly as it is, password included.
players = accounts.transform_values do |attributes|
  User.find_or_create_by!(email_address: attributes[:email_address]) do |user|
    user.display_name = attributes[:display_name]
    user.password = password
    user.password_confirmation = password
  end
end

existing = Match.where(mode: "online", red_user: players[:red], white_user: players[:white])
  .order(:id).first

if existing
  puts "[seeds] the demo game is already here: match #{existing.id}, " \
       "#{existing.result} by #{existing.reason}, #{existing.moves.count} moves"
else
  # Broadcasting is off for the replay. Every leg of this game would otherwise render the match
  # three times and write a Solid Cable row for an audience that does not exist, since nobody
  # is watching a match that is being seeded. Nothing else about the move path changes: the
  # transaction, the engine call and the row it writes are the ones a click makes.
  match = Match.silence_broadcasts do
    game = Match.open_online(creator: players[:red], colour: "red")
    game.join!(players[:white])

    demo_game.each_with_index do |text, index|
      # A jump is one move written as its landing squares joined by x, and it is played one leg
      # at a time, exactly as the board plays it.
      text.split(/[-x]/).map { |square| Integer(square, 10) }.each_cons(2) do |from, to|
        game.play_leg!(from, to)
      rescue Draughts::Error => error
        raise "db/seeds.rb: move #{index + 1} of the demo game (#{text}) is not legal " \
              "at that point: #{error.message}"
      end
    end
    game
  end

  # The engine, not this file, decides that the game is over and who won. If the list above
  # ever stops ending the game, the seed says so rather than leaving a half-played demo.
  unless match.finished? && match.result.present?
    raise "db/seeds.rb: the demo game did not finish (status #{match.status}, " \
          "#{match.moves.count} moves); the move list no longer ends the game"
  end

  puts "[seeds] demo game: match #{match.id}, #{match.result} by #{match.reason}, " \
       "#{match.moves.count} moves"
end

# What the run actually did to the accounts. find_or_create_by! sets the password only when it
# creates, so an account that was already here keeps whatever password it had, and printing the
# documented one for it would be untrue (session-7 audit, finding L1).
created, kept = players.values.partition(&:previously_new_record?)

if created.any?
  puts "[seeds] accounts created: #{created.map(&:email_address).join(", ")} (password #{password})"
end
if kept.any?
  puts "[seeds] accounts already here, left unchanged: #{kept.map(&:email_address).join(", ")} " \
       "(each keeps the password it had, which is #{password} unless it was changed)"
end
