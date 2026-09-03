import { Controller } from "@hotwired/stimulus"

// The copy button on the invite panel, and nothing else.
//
// The button is written into the page hidden and revealed here, so a browser with JavaScript
// switched off never shows a control that cannot do anything: it gets the link as text and as
// a link, which is what it can use.
//
// No rule and no state live here. Copying is navigator.clipboard where the browser allows it
// (a secure context, which localhost is), and selecting the field plus the old execCommand
// where it does not; if both fail the panel says so rather than claiming a copy that did not
// happen.
export default class extends Controller {
  static targets = ["source", "button", "status"]

  connect() {
    if (this.hasButtonTarget) this.buttonTarget.hidden = false
  }

  async copy(event) {
    event.preventDefault()
    const text = this.sourceTarget.value

    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text)
        return this.report("Invite link copied.")
      } catch {
        // Permission refused: fall through to the selection below.
      }
    }

    this.sourceTarget.focus()
    this.sourceTarget.select()
    const copied = document.execCommand && document.execCommand("copy")
    this.report(copied ? "Invite link copied." : "Press Ctrl+C to copy the selected link.")
  }

  report(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
