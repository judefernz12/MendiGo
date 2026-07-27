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
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/layout_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/trump_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/resilience_test.gd
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
- the player who opens the hidden trump must play a trump that turn if they
  hold one, may play anything if they do not, is the only player so
  constrained, the obligation clears once they play, and bots obey it too

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
- the same table, opened as a spectator, gives nothing away and does nothing:
  the seat drawn at the bottom belongs to somebody else, so it must stay face
  down, capped like every other seat, unclickable and named rather than called
  "You". The check deliberately hands the watcher a snapshot that puts that
  seat on turn with the table idle - the one moment a seated player would be
  free to act - and requires that clicking still selects nothing and no action
  button appears

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

It also covers watching and the handoff into the game. A watcher must not be
shown seat controls that would silently do nothing, and the lobby must count
the watchers for the players. The handoff check opens a lobby that already has
a game entry waiting - the case where the server's answer beat the scene into
existence - and requires it to consume that entry and hand the game scene the
match, the whole table, and the local player marked. A watcher's handoff must
carry `is_spectator` and never the host role, even on the host's connection.

`layout_test.gd` prints `ALL_LAYOUT_OK`. "The table looks cluttered" is
otherwise untestable, so the rules are written down here. It deals a real game,
projects every card and HUD element onto a 1280x720 screen through the real
camera, and asserts that nothing which must stay apart overlaps by more than a
few pixels: the local hand against the piles, captured 10s, hidden trump slot,
trick, action buttons and HUD panels; nameplates against cards, panels and each
other; and everything inside the screen. It also checks where a full 13-trick
pile lands, because the pile steps forward as it grows and a single captured
trick proves nothing.

Three whole-table properties are asserted too, because "it looks wrong" usually
means one of these: the table is vertically centred (no big blank band at one
end), it fills at least 70% of the screen in both axes, and a card in hand is
at least 100 px tall. That last one is a floor on how far the camera may be
pulled back - at y 6.7 a card drops to about 95 px and stops being readable.

Headless always comes up with a square window and refuses to resize, so this
test recomputes both the camera projection and the anchored HUD rects for the
shipping 1280x720 instead of reading the live viewport. Change the resolution
in `project.godot` and `VIEW` in the test has to change with it.

`trump_test.gd` prints `ALL_TRUMP_OK`. It walks the real game scene through the
whole closed-trump life cycle with hand-built snapshots, so it does not have to
wait for a void hand to turn up in a real game. It checks the card is set aside
face down, flips in place on reveal, and - the important one - that the card
which flies back to the hand is the very node from the trump slot rather than a
fresh one dealt out of the deck. It also checks the reveal obligation on the
client, and that "Reveal Trump" is offered the moment the turn starts rather
than only after a card is tapped.

The same life cycle is run again with the trump belonging to an opponent, and
there the check watches the *transition* rather than the end state: it samples
the card count every frame while the snapshot renders and fails if it ever
rises. A duplicate dealt from the deck is culled again by the opponent-stack
cap once rendering settles, so the final counts look correct even though the
player has already watched the stray card fly in from the middle of the table.

It also covers the table's signposting, which is what makes a 6- or 8-player
game readable: teammates' nameplates tinted blue and opponents' red, a thicker
gold ring on the seat that is on turn, the countdown ring following that seat
rather than living at the local one, the between-games countdown, and the
match-over screen (with Play Again for the host only, and Back to Menu for
everyone).

`resilience_test.gd` prints `ALL_RESILIENCE_OK`. It covers what happens when
things go wrong: a player dropping out (seat held, server takes over promptly
rather than after the full turn deadline, reconnect reclaims it), someone
joining a game already in progress (spectator, never a seat), two clients on
one machine sharing a saved identity (the live seat cannot be stolen), the host
leaving (the role passes to the next connected player), a short table with bots
off (refused, with a reason), and everybody leaving (the room is held briefly,
then closed).

Leaving is covered on both sides of the deal, because the right answer flips.
From the lobby, leaving must *remove* the player - a held seat there is a ghost
nobody can come back to, and it is what made a rejoin get refused as a second
window. Mid-match, the same action must *hold* the seat, because the hand is
already dealt. The checks also cover a tab closed without warning, seats staying
distinct after someone goes, the host handing the room over, and the fact that
no peer can remove anybody but itself.

It also pins down **where a client is sent when it arrives after the lobby**,
which is the check that would have caught the rejoin bug: `_room_entry_for`
must return the dealer-draw screen while the dealer is being picked and the
match setup *plus the current state* once a game is running, and it must build
that state for the returning player's own seat. Empty - "stay in the lobby" -
is only correct while the room really is in the lobby. The same checks run for
a watcher, and assert their snapshot leaks nothing: no hand face up, no card
carrying its real identity, `is_host` and `must_play_trump` both off.

See `docs/CONNECTION_EDGE_CASES.md` for the write-up, including what is
deliberately *not* handled.

`rules_test.gd`, `render_test.gd` and `layout_test.gd` take 1-3 minutes because
they wait out the server's real bot and trick-resolve delays; `layout_test.gd`
runs three whole tables (4, 6 and 8 players), so it is the slowest. The rest
are quick.
