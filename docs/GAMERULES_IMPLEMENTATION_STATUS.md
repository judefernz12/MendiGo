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
- Trick winner: highest trump, otherwise highest card of the lead suit
  (tested every trick, plus deterministic cases)
- **Trump counts only from the moment it is activated.** Each played card
  carries the trump state at the time it was played, and the trick is resolved
  from that, not from the trump state at the end of the trick. So if a king of
  diamonds is discarded while nothing is trump, and diamonds is then revealed
  as the trump, a 2 of diamonds played after the reveal beats it. The same
  applies to open trump: the off-suit card that activates the trump is itself
  a trump and wins, but the cards played before it are not.
  `GameRules.txt` only says the suit "becomes active permanently for the rest
  of the game", which does not settle the mid-trick case; this is the reading
  used at the table
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
  seated on so nobody else's choice can move them; bots fill whatever is left
  (tested)
- Asking for a **full** side trades places rather than being refused. Once a
  room fills up every move is a move into a full side, so refusing meant the
  teams froze the moment the last player arrived. The mover goes across and one
  player comes back the other way: a bot first, since it has no preference,
  otherwise whoever picked that side most recently - so the people who settled
  earliest are the least likely to be moved. The lobby button reads "Swap to A"
  instead of "Join A" so it is clear before it is pressed, and the trade can
  always be made again in the other direction (tested)
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
- Leaving is announced to the server rather than being inferred from a closed
  socket. From the lobby it removes the player outright, since there is no hand
  to come back to; once the cards are dealt it holds the seat instead (tested)
- Seat reservation and full-state resend on reconnect; an absent player's hand
  is played by the server at bot speed rather than stalling on the deadline.
  A reconnecting client is also sent back to the table - the dealer-draw screen
  or the match itself, depending on where the room is - instead of being left
  on the team picker (tested)
- Nobody may take a seat once the deal has begun. Latecomers, and anyone who
  asks to watch, become spectators: every hand redacted including the seat
  drawn at the bottom of their own screen, no host role, no obligations, no
  way to act. They follow the lobby, the dealer draw and the match start along
  with everybody else, and there is a Watch Instead button to become one
  deliberately (tested)
- See `docs/CONNECTION_EDGE_CASES.md` for the full disconnect/reconnect/join
  audit, what is handled and what is deliberately left alone

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
- the countdown ring also runs during the dealer draw and while the trump
  holder picks a card to hide - both have a 25 s server deadline behind them,
  and both used to run silently
- the trump-mode choice is a dialog in the middle of the table over a dimmed
  background, spelling out what closed and open trump each mean, with the time
  remaining. Other players see who is choosing. It used to be two unlabelled
  buttons in the bottom corner
- the bottom buttons sit in a centred bar, so a single button (Hide This Card)
  is centred under the hand instead of pinned to a slot meant for two
- Reveal Trump is the one button that glows, since it is rare and easy to miss
- between games a countdown sits in the middle of the table ("NEXT GAME IN 5")
- when the match is won, a full screen shows the winner and the final score,
  with Play Again for the host and Back to Menu for everyone

Four HUD anchors, one job each. Top left: the match panel - a labelled grid
with a row per team giving score, 10s (shown as `n / 4` against the court
target, highlighting as a team closes in) and tricks, then the dealer and whose
turn it is. Bottom right: the trump chip - a 40 px suit icon and the suit name,
next to the hand and the action buttons where the player is already looking (it
reads "Not set" in grey until the trump is decided). Top right, under the Leave
button: the lead chip. Top centre: the message banner, which also carries the
game result coloured by who won, so there is no separate result chip.

The lead chip names the suit led this trick, which you must follow if you hold
it - the other half of "what may I play?", and until it existed the only way to
learn it was to pick an illegal card and be told off. It reads "Open" before
anyone has played, and the suit name is gold while this hand still holds that
suit (so following is compulsory) and plain once void and free to play anything.
It only appears during play.

It sits left of the Leave button rather than directly beneath it: the space
directly below is the opposing team's captured-10s column (x 1189-1256,
y 81-271 at 1280x720), which leaves a 31 px band there - not enough for a
readable chip. Merging it into the trump chip as a second row was tried first
and made a mess of the bottom corner.

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
- side-stacked seats put their plate in the margin beside their cards, but that
  margin is also where the captured piles and 10s go. Those slots are reserved
  whether or not anything has landed in them yet, so a plate cannot take a spot
  a captured 10 will want three tricks later and then have to jump out of. If
  the outer margin is spoken for the plate tries the inner side, then slides
  along the outer side until it is clear
- the pile's forward step is 0.022 per trick; the old 0.13 walked a full pile
  most of a card-length across the table and off the bottom of the screen
- captured 10s are laid out in a column on the far side of their pile. All four
  slots for both teams are measured whether or not any have been captured yet -
  otherwise every check against them was quietly optional, depending on how the
  test's game happened to go. Making them unconditional immediately turned up
  an 8-player nameplate sitting on one
- the seat ring is a wide, flat ellipse centred on the camera axis, so the
  piles and the trump slot get the screen margins and the table sits in the
  middle of the screen. It widens with the player count (RX 2.8/3.3/3.55)
- everyone except the local player is spread over the arc left once a
  78-degree gap is kept clear around the bottom. Spreading all seats evenly
  put a neighbour right beside the local hand at 6 and 8 players
- the trick has its own even spread over the whole circle and its own ring
  size: with 8 cards to place it cannot afford the bottom gap
- played cards are laid down square at 6 and 8 players. The scatter tilt costs
  about 40% of a card's width in projection, which is what forced them small;
  dropping it takes them from 0.70/0.82 back up to 0.95/0.92 of full size
- each played card carries a team-tinted border (a slightly larger quad just
  behind its face), so a crowded trick can be read at a glance: blue came from
  your side, red from theirs
- the table is a stadium (a slab with round caps), not an ellipse - a 1.85:1
  ellipse reads as a stretched circle. Felt, rim and floor are three meshes at
  the card plane's depth so the rim shows all the way round
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
- Promoting a spectator into a seat that a player has left for good
- Sound, music, haptics, settings screen
- Card back / table theme cosmetics
- Reconnect restores state, not mid-animation position

## Deployment

See `docs/FREE_ONLINE_DEPLOYMENT.md`. Re-export the dedicated server whenever
`Server.gd` or `scripts/network/NetworkManager.gd` changes.
