# Be sure to restart your server when you modify this file.

# A match exports as a .pdn file (Portable Draughts Notation), which is plain text with a
# conventional extension. register_alias, not register: the media type stays text/plain, and
# the lookup from "text/plain" to a format keeps answering :text, so registering this cannot
# change how any other request is answered. What it adds is the :pdn format itself, which is
# what makes /matches/:id.pdn a route Rails will answer and format.pdn a branch respond_to
# understands.
Mime::Type.register_alias "text/plain", :pdn
