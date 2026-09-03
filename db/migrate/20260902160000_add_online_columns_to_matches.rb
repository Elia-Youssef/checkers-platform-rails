class AddOnlineColumnsToMatches < ActiveRecord::Migration[8.1]
  # What online play needs on top of the columns CreateMatches already reserved
  # (invite_token and draw_offered_by).
  #
  # invite_token_used_at is the token's own record of being spent, kept separately from the
  # status so that a link is dead the moment a seat is taken or the match is cancelled, and
  # stays dead whatever the status later becomes. A match with a used token can never be
  # joined again even if some future code puts the row back into "waiting".
  #
  # rematch_match_id points from a finished online match at the new waiting match Play again
  # created, which is how the invite link for the rematch reaches the opponent: the finished
  # match broadcasts, and the opponent's own controls fragment carries the link. It is on the
  # finished row rather than the new one because that is the row both players still have open.
  def change
    change_table :matches, bulk: true do |t|
      t.datetime :invite_token_used_at
      t.references :rematch_match, foreign_key: { to_table: :matches }
    end
  end
end
