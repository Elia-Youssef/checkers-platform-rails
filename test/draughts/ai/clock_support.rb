# frozen_string_literal: true

# A clock for the AI tests. Draughts::AI::Search takes its clock as an argument, so a test
# can hand in this one and cross a deadline without waiting a single millisecond for it.
#
# The nth call (counting from zero) returns start + n * step, so every number a test asserts
# is arithmetic rather than a measurement:
#
#   FakeClock.new                    time stands still at 0.0
#   FakeClock.new(step: 1.0)         every reading is a second later than the one before
#   FakeClock.new(start: 5, step: 2) 5.0, 7.0, 9.0, ...
#
# calls counts the readings, which is how a test checks that the search looks at the clock
# once a node while a deadline is live and not at all when there is none.
class FakeClock
  attr_reader :calls, :step

  def initialize(start: 0.0, step: 0.0)
    @start = start.to_f
    @step = step.to_f
    @calls = 0
  end

  def call
    value = @start + (@calls * @step)
    @calls += 1
    value
  end
end
