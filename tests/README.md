# Automated checks

These run the real `Server.gd`, the real `GameRoom3D.tscn` and the real
`Lobby.tscn` headlessly, with no network and no window. They are excluded from
every export preset.

Run from the project root (use the same Godot version as the project):

```powershell
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/rules_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/render_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/multiplayer_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/lobby_test.gd
```

`rules_test.gd` prints `ALL_RULES_OK` and exits 0 when every rule in
`GameRules.txt` that can be checked automatically holds. It plays a complete
4-player game against bots and verifies:

- deck size and 2s removal per player count (4/6/8)
- deal patterns 5+4+4 / 4+4 / 3+3, dealt in play direction from the dealer
- the deal pauses for the trump-mode choice
- trump holder is the player after the dealer
- hidden trump is redacted from every snapshot, including its holder's
- opponent hands are redacted
- follow-suit and out-of-turn plays are rejected
- every trick winner (highest trump, else highest lead suit)
- 4 tens, court = 5 points, normal = 2, tie broken by tricks
- a court ends the game the moment the fourth 10 is captured: the phase flips
  to `game_result`, no further card can be played, and the unplayed cards are
  left in hand so clients can clear the table normally
- dealer rotation and score carry-over into the next game
- team selection: a choice moves the player to that side's seats, nobody else
  is shuffled by it, a full side is refused, a choice from the wrong peer is
  refused, seats lock once the match starts, and bots fill what is left

`render_test.gd` prints `ALL_RENDER_OK` and exits 0 when the table renders
correctly. It feeds real server snapshots into the real game scene and checks:

- the opening deal is staggered: cards are still waiting at the deck half a
  second in, and the whole deal takes over a second (this fails if the deal
  animation collapses into a single instant move)
- the opening deal draws the right cards and reveals only the local hand
- opponent stacks are capped and physically compact
- opponent cards are never face up while in hand
- re-sending a snapshot does not re-create (re-deal) any card
- cards that stay in hand keep the same node while playing
- the hidden trump moves to its slot face down and only that card leaves hand
- completed tricks end up in a captured pile matching the server's counts
- captured 10s are displayed on the piles
- the scoreboard cells (score / 10s / tricks / dealer / turn / target) read
  back exactly what the drawn snapshot says
- a court raises the celebration overlay with its banner and confetti, the
  result chip and banner message both say COURT, resending the same result
  does not stack a second overlay, and a new game re-arms it

`multiplayer_test.gd` prints `ALL_MULTIPLAYER_OK`. It runs two clients in one
process from their own snapshots and checks they cannot desync: both must name
the same dealer and trump holder, exactly one may act as the holder, neither
may hold the other's cards, and a client handed the wrong lobby setup must
still recover its own seat from the server. It also checks that two humans who
pick the same side are seated as partners with the bots opposite.

`lobby_test.gd` prints `ALL_LOBBY_OK`. It drives the real lobby scene with real
server output and checks the team picker: each side lists the right players,
empty seats read as bots, the headers show how full each side is, the join
buttons reflect where the local player actually sits, and only the host sees
the start button.

`rules_test.gd` and `render_test.gd` take 1-3 minutes because they wait out the
server's real bot and trick-resolve delays; the other two are quick.
