import { Controller } from "@hotwired/stimulus"

// Selection, and where the keyboard is left standing. Nothing else.
//
// The game is fully playable with this file deleted: without JavaScript every square is a
// form, selecting a piece is a GET that re-renders the page with that piece's destinations,
// and a destination is a POST of one leg. This controller only saves the round trip for the
// selection itself.
//
// It holds no rule. The squares a piece may move to were computed by the Ruby engine on the
// server and printed into data-legal-targets; the two accessible names were written on the
// server as well and are only swapped here. Deciding whether a move is legal, whether a jump
// must continue, or whether the match is over never happens in this file: the server
// recomputes all of it from the stored position and answers 422 if the leg is not legal.

// Where the keyboard was, across a board that gets replaced.
//
// Every accepted leg is answered with a Turbo Stream that replaces the whole board element,
// which takes the focused square out of the document; the browser then parks focus on the
// body, so a keyboard player walked the skip link and the navigation again before every move.
// This flag lives in the module rather than on the controller instance, because the instance
// is torn down with the element it is attached to.
let boardHadFocus = false

export default class extends Controller {
  static targets = ["form", "from", "to"]
  static values = { selected: String, locked: Boolean }

  connect() {
    this.selected = this.selectedValue === "" ? null : Number(this.selectedValue)
    this.restoreFocus()
  }

  focusIn() {
    boardHadFocus = true
  }

  // Leaving the board on purpose (Tab to a control, a click on a link) names the element focus
  // moved to, and that clears the flag, so the opponent's page and a viewer's page keep their
  // own focus when an update arrives. Focus lost because the square itself was replaced names
  // nothing, and that is the case connect() puts right.
  focusOut(event) {
    if (event.relatedTarget && !this.element.contains(event.relatedTarget)) boardHadFocus = false
  }

  // Put the keyboard back on the board, and only when it was on the board and the browser has
  // dropped it. Nothing else is ever moved, and neither is the page: focus() scrolls its
  // element into view unless it is told not to, and the board is the top of a match page, so
  // on a narrow window an update from the opponent dragged a reader who had scrolled down to
  // the move list back up to the board (measured at 420 by 640: scrollY 542 before White's
  // reply arrived and 52 after). preventScroll takes the keyboard back without taking the
  // page; the sibling moves controller restores the window by hand for the same reason.
  restoreFocus() {
    if (!boardHadFocus) return
    if (document.activeElement && document.activeElement !== document.body) return

    const square = this.focusCandidates().find((element) => element && !element.disabled)
    if (square) square.focus({ preventScroll: true })
  }

  // Best first: the square the last move ended on, then the selected piece, then the first
  // destination on offer. Of the two squares the server marked as the last move, the one the
  // moved piece is standing on is the destination; the other one it came from is empty. A
  // square the server disabled is skipped, which is what puts the keyboard on the continuation
  // square while a jump is locked (the locked piece itself is rendered disabled). No rule is
  // decided here: every square in the list was drawn that way by the server.
  focusCandidates() {
    const marked = Array.from(this.element.querySelectorAll(".square--last-move"))

    return [
      marked.find((square) => square.querySelector(".piece")),
      this.element.querySelector(".square--selected"),
      this.element.querySelector(".square--target")
    ]
  }

  // One click anywhere on the board.
  click(event) {
    const square = event.target.closest("[data-square]")
    if (!square || square.disabled) return

    // While a jump sequence is pending the server has already reduced the board to the
    // continuation squares and disabled everything else, so the plain form is exactly right.
    if (this.lockedValue) return

    event.preventDefault()
    const number = Number(square.dataset.square)

    if (this.selected !== null && this.targetsOf(this.selected).includes(number)) {
      this.submitLeg(this.selected, number)
    } else if (square.dataset.legalTargets && number !== this.selected) {
      this.selected = number
      this.paint()
    } else {
      this.selected = null
      this.paint()
    }
  }

  submitLeg(from, to) {
    if (!this.hasFormTarget) return

    this.fromTarget.value = from
    this.toTarget.value = to
    this.formTarget.requestSubmit()
  }

  targetsOf(number) {
    const square = this.squareElement(number)
    const list = square ? square.dataset.legalTargets : ""
    return list ? list.split(" ").map(Number) : []
  }

  squareElement(number) {
    return this.element.querySelector(`[data-square="${number}"]`)
  }

  paint() {
    const targets = this.selected === null ? [] : this.targetsOf(this.selected)

    this.element.querySelectorAll("[data-square]").forEach((square) => {
      const number = Number(square.dataset.square)
      const isSelected = number === this.selected
      const isTarget = targets.includes(number)

      square.classList.toggle("square--selected", isSelected)
      square.classList.toggle("square--target", isTarget)
      square.setAttribute("aria-label", isTarget ? square.dataset.labelTarget : square.dataset.labelIdle)
      if (square.dataset.legalTargets) square.setAttribute("aria-pressed", String(isSelected))
      else square.removeAttribute("aria-pressed")
    })
  }
}
