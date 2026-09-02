import { Controller } from "@hotwired/stimulus"

// Selection, and nothing else.
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
export default class extends Controller {
  static targets = ["form", "from", "to"]
  static values = { selected: String, locked: Boolean }

  connect() {
    this.selected = this.selectedValue === "" ? null : Number(this.selectedValue)
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
