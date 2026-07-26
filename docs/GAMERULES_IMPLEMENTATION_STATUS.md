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
- Follow suit enforced; out-of-turn, duplicate and late plays rejected (tested)
- Trick winner: highest trump, otherwise highest card of the lead suit,
  stamped with the trump state used to resolve it (tested every trick)
- Trick capture with the captured 10s recorded per team (tested)
- Court = 5 points, normal = 2, equal 10s decided by tricks, equal both = draw
  with no points (tested)
- Match ends at the target score; otherwise the next game starts automatically
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
  hand flips face up (tested)
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
