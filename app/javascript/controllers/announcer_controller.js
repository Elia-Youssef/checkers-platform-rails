import { Controller } from "@hotwired/stimulus"

// Speaking the status line after an update, and nothing else.
//
// Every accepted action replaces the whole status fragment, and the role="status" paragraph
// lives inside it. A replaced live region is a new node, and a screen reader announces changes
// to the region it was already watching, not to one that has just been inserted: measured in
// the round-2 accessibility audit (finding M2), the opponent and every viewer were told
// nothing when a move arrived. The page therefore carries one live region that nothing ever
// replaces (#match-announcer in matches/show), and this controller copies the server's
// sentence into it.
//
// connect() runs when the status fragment first appears and again every time Turbo replaces
// it, whether the replacement came from this browser's own response or from a broadcast. The
// first connect is the page load itself, whose sentence the reader has just read anyway, so it
// only primes the region; every later connect writes.
//
// No rule and no wording is decided here: the sentences are the ones the server rendered, read
// out of the elements it marked. With JavaScript off there is no replacement to miss, this
// file never runs, and the region stays empty.
export default class extends Controller {
  static targets = ["sentence"]

  connect() {
    const region = document.getElementById("match-announcer")
    if (!region) return

    const sentence = this.sentenceTargets
      .map((element) => element.textContent.trim())
      .filter((text) => text.length > 0)
      .join(". ")
    if (sentence.length === 0) return

    if (region.dataset.primed !== "true") {
      region.dataset.primed = "true"
      region.dataset.sentence = sentence
      return
    }
    if (region.dataset.sentence === sentence) return

    region.dataset.sentence = sentence
    region.textContent = sentence
  }
}
