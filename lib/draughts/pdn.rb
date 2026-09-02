# frozen_string_literal: true

module Draughts
  # PDN (Portable Draughts Notation): move text, numbered move pairs and file export.
  #
  # A quiet move is written from-to ("11-15"), a jump lists every landing square joined by
  # x ("24x15x8"), and a whole game is numbered in pairs, Red first:
  #
  #   1. 11-15 22-18 2. 15x22 25x18
  #
  # An exported file carries the headers the brief pins, in this order: Event, Site, Date,
  # Red, White, Result and GameType, where GameType "21" is English draughts on an 8 by 8
  # board with Red (the side that moves first) at the bottom.
  module PDN
    RESULT_STRINGS = { red_won: "1-0", white_won: "0-1", draw: "1/2-1/2" }.freeze
    UNFINISHED = "*"
    GAME_TYPE = "21"
    UNKNOWN_DATE = "????.??.??"
    LINE_WIDTH = 80
    HEADERS = %w[Event Site Date Red White Result GameType].freeze

    # One numbered pair of the move list. white is nil on the last row of a game that ended
    # after Red's move.
    Pair = Data.define(:number, :red, :white)

    def self.move_text(move)
      move.is_a?(Move) ? move.pdn : move.to_s
    end

    # The moves as numbered pairs. first_side says who played the first move, which is Red in
    # every real game and is only ever White for a game set up from a position.
    def self.pairs(moves, first_side: Side::RED)
      texts = moves.map { |move| move_text(move) }
      texts.unshift(nil) if first_side == Side::WHITE
      texts.each_slice(2).with_index(1).map do |(red, white), number|
        Pair.new(number: number, red: red, white: white)
      end
    end

    # "1. 11-15 22-18 2. 15x22 25x18", wrapped at width columns as a .pdn file is.
    def self.move_list(moves, first_side: Side::RED, width: LINE_WIDTH)
      wrap(tokens(moves, first_side: first_side), width)
    end

    # "1-0", "0-1", "1/2-1/2", or "*" while the game is unfinished.
    def self.result_string(result)
      return UNFINISHED if result.nil?

      RESULT_STRINGS.fetch(result.to_sym) do
        raise InvalidPosition, "not a result: #{result.inspect}"
      end
    end

    # The whole game as the text of a .pdn file. date accepts a String already in PDN form,
    # anything that answers to strftime, or nil for the unknown date.
    def self.export(game, event: "Casual game", site: "checkers-ruby", date: nil,
                    red: "Red", white: "White")
      result = result_string(game.result)
      values = { "Event" => event, "Site" => site, "Date" => format_date(date),
                 "Red" => red, "White" => white, "Result" => result, "GameType" => GAME_TYPE }
      lines = HEADERS.map { |name| header(name, values.fetch(name)) }
      body = tokens(game.moves, first_side: first_side_of(game)) << result
      "#{lines.join("\n")}\n\n#{wrap(body, LINE_WIDTH)}\n"
    end

    # ["1.", "11-15", "22-18", "2.", ...]
    def self.tokens(moves, first_side: Side::RED)
      out = []
      pairs(moves, first_side: first_side).each do |pair|
        out << "#{pair.number}."
        out << (pair.red || "...")
        out << pair.white if pair.white
      end
      out
    end
    private_class_method :tokens

    def self.header(name, value)
      %([#{name} "#{value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }}"])
    end
    private_class_method :header

    def self.format_date(date)
      return UNKNOWN_DATE if date.nil?
      return date.strftime("%Y.%m.%d") if date.respond_to?(:strftime)

      date.to_s
    end
    private_class_method :format_date

    # Which side played the first move of this game, worked out from its own history.
    def self.first_side_of(game)
      game.plies.even? ? game.side_to_move : Side.opponent(game.side_to_move)
    end
    private_class_method :first_side_of

    def self.wrap(tokens, width)
      lines = []
      line = nil
      tokens.each do |token|
        if line.nil?
          line = token.dup
        elsif line.length + 1 + token.length <= width
          line << " " << token
        else
          lines << line
          line = token.dup
        end
      end
      lines << line unless line.nil?
      lines.join("\n")
    end
    private_class_method :wrap
  end
end
