# The content security policy, on in every environment.
#
# The game is server-rendered HTML with two stylesheets, an importmap and three small Stimulus
# controllers, all served from this origin, so the policy can be tight: nothing loads from
# anywhere else, no page carries an inline event handler, and the two inline scripts that do
# exist are the ones importmap-rails writes (the import map itself and the one module import),
# which carry the per-request nonce automatically.
#
# What each directive is for here:
#
#   default_src :self       the fallback for anything not named below
#   script_src  :self       plus the nonce, added by nonce_directives below
#   style_src   :self       plus the nonce, for Turbo's progress bar: it builds a <style>
#                           element in JavaScript and stamps it with the nonce it reads from
#                           the csp-nonce meta tag in the layout. Nothing else is inline.
#   connect_src :self       Action Cable's websocket. CSP level 3 lets 'self' match ws:// and
#                           wss:// on this origin, which is where /cable is; a system test
#                           asserts the socket really connects under the policy rather than
#                           trusting that.
#   img_src     :self :data the three generated favicons under public/. The game itself uses
#                           no image at all (TASK-BRIEF.md section 1.8); data: is here so an
#                           inline SVG that ever needs a data URL does not need a policy change.
#   font_src    :self       system fonts only, so nothing is fetched; named for completeness.
#   object_src  :none       no plugins.
#   base_uri    :self       a <base> tag cannot be injected to re-point every relative URL.
#   form_action :self       a form cannot be made to post the session cookie elsewhere.
#   frame_ancestors :none   no framing, so the board cannot be clickjacked.
#
# The nonce is 16 random bytes per request, not the session id: it must be unguessable, and a
# visitor with no session yet (the home page of a first visit) has no session id to use.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.script_src      :self
    policy.style_src       :self
    policy.connect_src     :self
    policy.img_src         :self, :data
    policy.font_src        :self
    policy.object_src      :none
    policy.base_uri        :self
    policy.form_action     :self
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[ script-src style-src ]
end
