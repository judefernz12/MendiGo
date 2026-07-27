# GameRules Implementation Status

Tracks the repo against `GameRules.txt`. Items marked (tested) are covered by
the automated checks in `tests/` - see `tests/README.md`.

## Rules implemented (server-authoritative)

- Deck per player count: 52 for 4, 48 with the 2s removed for 6/8 (tested)
- Deal patterns 5+4+4 / 4+4 / 3+3, dealt in batches in play direction
  starting with the player after the dealer (tested)
- The deal pauses after the first batch for the trump-mode choice (tested)
- Dealer draw with unique ranks, first valid claim wins, bots auto-claim,
  server timeout auto-claims for absent players (tested)
- Trump holder is the first served player, i.e. the one after the dealer,
  following the room's play direction (tested)
- Closed trump: the hidden card leaves the hand and is redacted from every
  snapshot, including the holder's own (tested)
- Open trump: the first off-suit card played by a void player sets the trump
- Hidden trump reveal: only the player on turn and only when void in the lead
  suit; the card flips face up for 3 seconds, then returns to the holder's
  hand; play is blocked for the whole reveal
- The player who opened the trump must play a trump on that same turn if they
  hold one, and is free to play anything if they do not. Enforced for humans
  and bots, mirrored on the client so illegal cards cannot even be picked, and
  cleared as soon as they play (tested). **This rule is not in
  `GameRules.txt`** - it was added on request; the spec only says legal play
  "must account for the newly returned trump card"
- Follow suit enforced; out-of-turn, duplicate and late plays rejected (tested)
- Trick winner: highest trump, otherwise highest card of the lead suit,
  stamped with the trump state used to resolve it (tested every trick)
- Trick capture with the captured 10s recorded per team (tested)
- Court = 5 points, normal = 2, equal 10s decided by tricks, equal both = draw
  with no points (tested)
- A court ends the game as soon as the fourth 10 is captured rather than
  playing out dead tricks; the unplayed cards stay in hand so the table can be
  cleared with the normal next-game animation, and the result carries an
  `ended_early` flag (tested). This is a deliberate refinement of the
  "a game ends when all cards have been played" line in `GameRules.txt`: once
  one team holds all four 10s the court is mathematically locked in
- Teams still follow alternating seats, but players may pick a side in the
  lobby. The choice is stored per player and resolved into a seat of that
  side's parity; a player who never picked is pinned to the side they were
  seated on so nobody else's choice can move them; a full side is refused;
  bots fill whatever is left (tested)
- The next game starts automatically 5 s after a result (9 s after a court, so
  the celebration can finish). The delay is sent in the snapshot so the client
  can show an honest countdown rather than guessing
- Match ends at the target score and stops there with a match-over screen.
  The host may start a rematch on the same table: same seats, scores back to
  zero, the deal passing on as it would between games (tested)
- Dealer rotation: dealer's team wins -> pass the deal on; loses normal ->
  same dealer; loses court -> skip one seat (tested)
- Scores carry across games in a match (tested)
- Server turn deadlines (20 s play, 25 s choices) with autoplay
- Bots play legal cards after a short think delay
- Seat reservation and full-state resend on reconnect
- Spectator snapshots redacted

## Animations implemented (client)

The client renders the difference between the last drawn state and the new
snapshot, so cards are reused rather than re-created. A full snap-rebuild is
only used for the first paint of a game already in progress (reconnect) or if
a delta cannot be reconciled.

- Deal: cards fly from the deck one at a time in deal order, then the local
  hand flips face up (tested, including that the stagger really happens)
- Opponent hands draw at most 4 tightly spaced card backs, so 6- and 8-player
  tables stay readable. The real hand size stays on the server; the stack is
  topped up silently after each play (tested)
- Play: the card already in the hand moves to the trick slot and flips (tested)
- Trick capture: the whole trick flies to the winning team's pile, which
  stacks with an offset; captured 10s are laid out face up beside it (tested)
- Hidden trump: the chosen card slides face down to the trump slot, flips on
  reveal, and slides back into the holder's hand afterwards (tested for the
  set-aside step)
- Dealer draw: claimed cards animate to the claimer once and are never
  re-animated
- Trump icon pop-in, turn timer ring, per-seat nameplates with turn highlight
- Manual hand sorting survives later deals (new cards append, no re-order)
- Court celebration: a full-screen banner pops in with the points won, plus
  confetti when it is your team. The result chip and the phase banner both call
  the court out. Losing a court shows the same banner in a colder style with no
  confetti. The server holds the result for 12 s instead of 8 s so the
  celebration can finish (tested)

## HUD and table layout

Reading the table at a glance:

- every seat carries a tinted nameplate - blue for your side, red for the
  opposition. This matters most at 6- and 8-player tables, where your partners
  are not simply the player opposite you
- the seat on turn gets a thick gold ring around its plate that breathes, and
  the countdown ring moves to that seat, so whose turn it is reads from
  anywhere on the table instead of only from the colour of the name
- between games a countdown sits in the middle of the table ("NEXT GAME IN 5")
- when the match is won, a full screen shows the winner and the final score,
  with Play Again for the host and Back to Menu for everyone

Three HUD anchors, one job each. Top left: the match panel - a labelled grid
with a row per team giving score, 10s (shown as `n / 4` against the court
target, highlighting as a team closes in) and tricks, then the dealer and whose
turn it is. Bottom right: the trump chip - a 40 px suit icon and the suit name,
next to the hand and the action buttons where the player is already looking
(it reads "Not set" in grey until the trump is decided). Top centre: the
message banner, which also carries the game result coloured by who won, so
there is no separate result chip.

Table geometry is checked, not eyeballed. `tests/layout_test.gd` projects every
card and HUD element onto a 1280x720 screen through the real camera and asserts
that things which must not sit on top of each other do not: the local hand
against the piles, the captured 10s, the hidden trump slot, the trick, the
action buttons and the panels; nameplates against cards, panels and each other;
and everything against the screen edges. It also checks where a full 13-trick
pile ends up, since the pile steps forward as it grows, and three whole-table
properties: that the table is vertically centred, that it fills at least 70% of
the screen in both axes, and that a card in hand is at least 100 px tall.

Notable consequences of that check:

- nameplates are placed in screen space, just clear of the projected bounds of
  the cards they belong to, flipping above them if there is no room below.
  They used to be lerped towards the table centre and landed on the cards
- the pile's forward step is 0.022 per trick; the old 0.13 walked a full pile
  most of a card-length across the table and off the bottom of the screen
- captured 10s are laid out in a column on the far side of their pile
- the seat ring is a wide, flat ellipse (RX 2.8, RZ 1.60) centred on the
  camera axis, so the piles and the trump slot get the screen margins and the
  table sits in the middle of the screen
- the camera stays at y 6.069. Raising it to 6.7 shrank a hand card from 111 px
  to about 95 px tall, which is why the size floor is now asserted
- opponent cards stand upright, so stacking them with only a vertical offset
  left their faces coplanar and they z-fought (a visible flicker). Each card is
  now pushed slightly outwards along the seat's radius, the direction its face
  points, and they are spaced 0.22 apart rather than 0.18

## Still needs manual testing in the editor

- A live 2-client game against the deployed server
- A 6-player and an 8-player table (layout is generated, not yet played)
- The hidden-trump reveal animation end to end (needs a void hand)
- Web and Android builds

## Not implemented (non-blocking)

- Public matchmaking, friends invite, chat and emotes
- Dedicated spectator UI
- Sound, music, haptics, settings screen
- Card back / table theme cosmetics
- Reconnect restores state, not mid-animation position

## Deployment

See `docs/FREE_ONLINE_DEPLOYMENT.md`. Re-export the dedicated server whenever
`Server.gd` or `scripts/network/NetworkManager.gd` changes.
