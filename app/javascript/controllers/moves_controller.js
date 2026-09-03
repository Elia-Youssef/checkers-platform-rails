import { Controller } from "@hotwired/stimulus"

// Scrolling, and nothing else.
//
// The move list is a fixed-height box with its own scrollbar, so in a long game the
// highlighted move (the latest one on a match page, the replayed ply on a replay page) sits
// below the fold and the reader has to scroll to find what the page is telling them about.
// This brings it into view.
//
// connect() runs when the list first appears and again every time a Turbo Stream replaces the
// list, which is what makes the latest move stay in view as a game is played and as a replay
// steps. Nothing here decides a rule, reads a value or talks to the server: the marked element
// is marked by the server, and this file only scrolls to it. With JavaScript off nothing is
// lost but the convenience: the list is complete and the reader scrolls it by hand.
export default class extends Controller {
  connect() {
    const marked = this.element.querySelector(".moves__move--latest")
    if (!marked) return

    const x = window.scrollX
    const y = window.scrollY

    // "nearest" scrolls each scrollable ancestor by the least it can, so a move already in
    // view moves nothing at all.
    marked.scrollIntoView({ block: "nearest", inline: "nearest" })

    // Only the list's own box is meant to move. scrollIntoView will also scroll the document
    // when the list itself is off screen (a narrow window, where the list sits under the
    // board), and a page that jumps away from the board on load is worse than a move the
    // reader has to scroll to, so the page is put back where it was.
    if (window.scrollX !== x || window.scrollY !== y) window.scrollTo(x, y)
  }
}
