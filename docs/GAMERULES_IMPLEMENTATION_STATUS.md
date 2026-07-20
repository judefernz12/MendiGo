# GameRules Implementation Status

This file tracks the repo against `GameRules.txt`.

## Implemented In Code

- WebSocket multiplayer transport for Web, Android, and Desktop.
- Dedicated headless authoritative server scene.
- Private room creation and join by code.
- Room settings: player count (4/6/8), play direction, target score,
  bot fill, spectators.
- Absolute seat IDs on the server; alternating teams by seat.
- Deck creation: 52 cards for 4 players, 48 (2s removed) for 6/8.
- Deal patterns: 5+4+4 / 4+4 / 3+3 with the pause after the first batch
  for the trump-mode choice.
- Dealer draw with unique ranks, first-claim wins, bot auto-claims,
  and a server timeout that auto-claims for absent humans.
- Dealer and trump-holder selection by play direction.
- Closed and open trump, hidden-trump reveal rules, auto-return of the
  hidden trump card.
- Server validation: identity, room, seat, turn order, card ownership,
  follow suit, reveal eligibility, duplicate/late plays.
- Server-side trick resolution with a visible pause so all clients see
  the completed trick before it is captured.
- Court/normal scoring (5/2 points), draw handling for 6/8-player games
  (equal 10s and equal tricks = no points, same dealer redeals).
- **Multi-game matches**: after each game result the server rotates the
  dealer by the GameRules rules (win: pass dealer, lose normal: same
  dealer, lose court: skip one) and starts the next deal automatically,
  carrying scores until the target score ends the match.
- **Server-side turn deadlines**: 20 s per play and 25 s for trump
  choices; the server autoplays/auto-picks so a stalled or disconnected
  player can no longer hang the game.
- Bots with a short thinking delay.
- Reconnect: seat reservation by player id + full snapshot on rejoin.
- Spectator snapshot redaction.
- Client: perspective remapping for **4, 6 and 8 players** (elliptical
  seat rings, per-seat nameplates with turn highlight and dealer tag),
  hand sorting that persists across snapshots, turn timer ring,
  scoreboard panel, leave button, connection-loss message.
- Clean shared UI theme across Home / Online / Lobby / Game screens,
  How To Play summary on the home screen, copy-room-code button.
- Host-push state channel disabled server-side (anti-cheat).

## Still Needs Godot Editor Testing

- Open the project in Godot 4.6 once so new resources import
  (theme, scene UIDs).
- End-to-end test: local server + 2 desktop clients (`--local-server`).
- A 6-player and an 8-player round with bots.
- Web export test, then online test through the deployed server.
- Re-export `server/server.x86_64` + `server.pck` (the committed ones
  predate all of these changes).

## Still Incomplete Or Partial (non-blocking)

- Reconnect does not restore mid-animation state perfectly.
- No dedicated spectator UI (spectators watch via redacted snapshots).
- Public matchmaking, friends invite, chat/emotes are not implemented.
- The client turn-timer ring is cosmetic; enforcement is server-side.
- No sound/music/haptics/settings screen yet.
- Hidden-trump reveal is shown via state rebuild, not a 3-second
  flip animation.
- Card backs/table themes are fixed (no cosmetics UI).

## Manual Setup Required

See `docs/FREE_ONLINE_DEPLOYMENT.md` (Render + itch.io free path).
