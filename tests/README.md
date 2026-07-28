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
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/orientation_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/settings_test.gd
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
- the room code is on the table, in the top-left panel with the rest of the
  status. It used to be on the lobby screen only, so once the deal started
  there was no way to read it back without leaving the game to go and look -
  which is exactly when somebody asks to join or to watch. It is read from the
  drawn snapshot so the code on screen always belongs to the table on screen,
  falling back to the joined room for the moments before the first snapshot
- a court raises the celebration overlay with its banner and confetti, the
  result chip and banner message both say COURT, resending the same result
  does not stack a second overlay, and a new game re-arms it
- the lead chip names the suit led this trick, with its icon, highlighted only
  while this hand still holds that suit and is therefore bound to follow it,
  and reading "Open" with no icon before anyone has played. It is its own chip:
  the trump chip is left exactly as it was
- both suit icons are measured **as drawn**, and the lead chip is checked
  against the size its own offsets ask for. The suit art is over 1100 px
  square and a `TextureRect` treats that as its minimum size unless
  `expand_mode` is set, so an icon can silently drag its container open;
  `custom_minimum_size` will not stop it, and the layout suite measures panels
  from their anchors so it cannot see it happen
- a watcher gets a nameplate for every seat, the bottom one included, showing
  that player's real name - it used to be skipped, because for a player the
  bottom seat is themselves, which was the one missing name tag. That plate
  shares the bottom strip with the WATCHING badge, which used to clip it
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

It also covers the **online menu, which is three short screens rather than one
long one**. Everything used to be stacked on a single card - room settings, a
code box and every button - so a phone showed half of it and the half you
wanted was often below the fold. The first screen now only asks what you came
to do, and the checks pin that: it opens on the chooser and shows nothing else,
creating, joining and watching are all offered there, and the room settings
live on the create page rather than in front of somebody who came to join.
Join and Watch reach the same code box but must not mean the same thing when it
is submitted - a seat, or none - so the flag, the button's own wording and the
title are all checked for both. Back goes up one level rather than hanging up
on the server, and with nothing typed the Join button says so instead of
answering a tap with silence.

It also covers the id clash between two clients on one machine. They share
`user://identity.cfg` and so share a player id whatever their names are; the
server refuses the second one and the client must silently retry with a fresh
id. The check pins the part that was broken: the retry has to use the room being
*attempted*, since `current_room_code` is only set once a join has succeeded, so
on a first join it is empty and nothing happened at all.

It also covers watching, side-swapping and the handoff into the game. A watcher
must not be shown seat controls that would silently do nothing, and the lobby
must count the watchers for the players. A side with room reads as "Join A"; a
full one reads "Swap to A" and stays clickable, with a tooltip saying it will
trade places - a full side used to be a dead button. The handoff check opens a lobby that already has
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
in `project.godot` and `BASE_VIEW` in the test has to change with it.

**The whole table is then re-measured at the other shapes a window can be** -
1560x720 and 1707x720 (a phone held sideways), 1280x800 and 1280x960 (a laptop
or a browser window taller than 16:9). The game is designed at 1280x720 but
stretches with `expand`, so the viewport is whatever shape the window is, and
measuring only the design size hid a bug on every phone. The camera keeps its
vertical FOV, so widening a window does not move the seats - the extra pixels
all arrive as margin down the sides - which means anything deciding "is this
seat up the side of the screen?" has to measure against the **height**. It
measured against the width, so on a phone the goalposts moved out past seats
that had not moved: the side seats were treated as centre seats, their names
were placed under their own cards, pushed down past the neighbouring seat's
cards, and two names landed in the same spot (118x24 px of overlap on an
8-player table). Taller than 16:9 the same routine failed the other way, with
the side margin too narrow to hold a plate at all and the plate clamped back on
top of the cards it belongs to.

Nameplates are measured at the size they are really drawn at rather than at
`NAMEPLATE_SIZE`, which is only a floor: a `Label` grows to fit its text, and a
long name with `(Dealer)` after it is a good deal wider than the constant.

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

Abandoned rooms get their own checks, because a watcher used to keep one alive
indefinitely: no seated players, the server playing every hand to itself, and
no way for anyone to start a rematch since the host role needs a seat. The
checks require the room to be marked for cleanup as soon as the last *player*
goes even with watchers present, to survive the sweep if a player comes back,
to be closed by the sweep if none does, and to detach every watcher when it
closes. The same applies to a lobby nobody is sitting in. The sweep's decision
is split out as `_sweep_empty_room_now` so it can be checked without waiting
out the three-minute grace period.

Leaving is covered on both sides of the deal, because the right answer flips.
From the lobby, leaving must *remove* the player - a held seat there is a ghost
nobody can come back to, and it is what made a rejoin get refused as a second
window. Mid-match, the same action must *hold* the seat, because the hand is
already dealt. The checks also cover a tab closed without warning, seats staying
distinct after someone goes, the host handing the room over, and the fact that
no peer can remove anybody but itself.

**Watch and Join have to mean different things.** Coming back with Watch must
put the player in the audience and leave their seat auto-played, not hand it
straight back; the server must then refuse a card played from that connection,
whatever the client sends; and Join must take the seat back and clear them from
the audience. From the lobby the same swap gives the seat up entirely, because
there is no hand to hold it for.

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

`orientation_test.gd` prints `ALL_ORIENTATION_OK`. It covers the rotate prompt
and, mostly, the conditions that decide when it appears - getting those wrong
is worse than having no prompt at all, since a stray overlay is a permanent
black screen over a game that was working. It checks that real phone
resolutions read as portrait and the same phones turned read as landscape;
that 1280x720, a laptop window, a square viewport and a zero-sized viewport all
read as landscape (a viewport reports zero for a frame while scenes swap, and
the headless viewport this suite runs in is square); that a desktop run never
arms the prompt at all; that native handheld builds are pinned to sensor
landscape so the prompt could never be right there; that the overlay covers the
whole screen at any size and swallows input; that the wording mentions rotation
lock; and that the orientation lock is attempted once, only from a real press,
and never from a finger lift.

`settings_test.gd` prints `ALL_SETTINGS_OK`. It covers what the app remembers
between runs and how a player gets characters into a text box - "shell"
behaviour rather than game rules.

Sorting the hand is off unless it is asked for, which is checked on a freshly
constructed settings object rather than on the live one: turning it on by
default would change how the game plays for everybody who never opened the
menu. Settings are written and read back to prove they survive a restart, the
panel is checked to open showing what is actually set (not its own defaults),
and unticking a box has to reach the stored setting rather than only the
checkbox, because the table reads the setting and never the box. The name typed
in the panel has to land in `profile.cfg`, since that is where every other
screen looks for it.

**Text entry on a phone browser** is the other half. Godot draws its own
`LineEdit` on a canvas, so the browser does not know a text field exists; the
engine asks for a keyboard and feeds the result through a hidden element, and
that path only survives keyboards which send ordinary key events. Samsung's
does. Gboard and iOS Safari compose text - autocorrect, suggestions, swipe -
and deliver it as an input event, so the keyboard opened and typing went
nowhere, or on iOS did not open at all. A real `<input>` is now placed over the
canvas where the field is drawn instead.

The browser half cannot be checked headlessly - there is no page here - so what
is checked is the part that was actually wrong: **the conditions** that decide
whether any of it runs (never outside a touch browser, and every entry point
safe to call anyway, because the screens call them without testing the platform
themselves), and **the placement maths**, including a field inside a
`CanvasLayer`, which the game's HUD uses. Getting that wrong is worse than the
bug it fixes: an invisible input box in the wrong place is one nobody can tap.

`rules_test.gd`, `render_test.gd` and `layout_test.gd` take 1-3 minutes because
they wait out the server's real bot and trick-resolve delays; `layout_test.gd`
runs three whole tables (4, 6 and 8 players), so it is the slowest. The rest
are quick.
