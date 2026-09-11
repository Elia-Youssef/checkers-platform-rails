import { Controller } from "@hotwired/stimulus"

// Saying out loud that something changed. Nothing else.
//
// The status fragment carries this controller, and a Turbo Stream replaces that fragment after
// every accepted action: the acting browser gets it in its own response, the opponent and every
// viewer get it over Action Cable. Stimulus connects the new element each time, which is the
// event this file turns into an announcement.
//
// It holds no rule and no state of the game. The sentence it copies was written on the server
// by the status partial ("White to move", "White to move: finish the jump from square 15",
// "Ada (Red) has offered a draw.", "Red wins, no pieces left"), and this only moves that text
// into the one live region in the layout, which is outside every fragment a stream replaces and
// therefore still the same element the screen reader was watching before the update. With
// JavaScript off there is no update to announce: the whole page reloads and the status
// paragraph is read where it stands.
//
// Two deliberate details:
//
//   * The first connect on a page says nothing. A live region is for what changes after the
//     page has settled, and announcing the status the moment a match page opens would talk over
//     the reader arriving on it. The region remembers what it was last told on itself, so a
//     Turbo Drive visit (which replaces the body, and the region with it) starts silent again.
//
//   * The message is put in as a new child element rather than as replacement text, so an
//     update whose sentence happens to read the same as the last one is still announced. That
//     is the computer-opponent case: the human moves, the engine answers inside the same
//     request, and the status comes back saying "Red to move" exactly as it did before.
export default class extends Controller {
  static targets = ["message"]

  connect() {
    const region = document.getElementById("live-announcer")
    if (!region) return

    const message = this.message()
    const first = region.dataset.announced === undefined
    region.dataset.announced = message

    if (first || message === "") return

    const line = document.createElement("p")
    line.textContent = message
    region.replaceChildren(line)
  }

  // The status sentences of this fragment, in the order they are printed, as one line.
  message() {
    return this.messageTargets
      .map((element) => element.textContent.trim().replace(/\s+/g, " "))
      .filter((text) => text !== "")
      .join(". ")
  }
}
