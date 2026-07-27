# What happens when things go wrong

Every case below was checked against the real `Server.gd`. The ones marked
(tested) are covered by `tests/resilience_test.gd`; run it and it will tell you
if any of this stops being true.

## Handled

### A player leaves from the lobby (tested)

Their entry is **removed**. In the lobby there is no hand to come back to, so a
held seat is pure ghost: the room reads as fuller than it is, the team columns
count somebody who has gone, and - the part that actually bit - the leaver's own
rejoin collided with their stale entry and was refused as a second window,
telling them the name was already taken.

Leaving is also announced now. It used to be nothing but a closed socket, so the
server did not find out until the WebSocket teardown crossed the internet. A
client that left, re-dialled and rejoined did all three faster than that, and so
arrived *before* its own departure. `_server_leave_room` is sent first and the
socket closes a moment later, so the order is never in doubt.

A tab closed without warning is handled the same way: any disconnect while the
room is still in the lobby removes the player rather than reserving a seat.

### A player leaves or their connection drops mid-match (tested)

Their seat is **held**, not freed - this is the opposite of the lobby case,
because the cards are already dealt and the hand is theirs. This applies to a
deliberate leave too: they stay in the room marked `is_connected = false`, and
the server plays their hand for them.

Before this pass the server did take over, but only through the 20-second turn
deadline: every one of their turns stalled the whole table for the full 20 s.
An absent human is now treated the same as a bot for turn timing, so play
continues at the normal ~1 s bot pace. If they come back they get their seat,
their hand and the full state.

### A player reconnects (tested)

The client's player id is now saved in `user://identity.cfg`, so a reconnect
after a dropped connection - or after closing and reopening the app - reclaims
the same seat. It used to generate a new id every launch, which meant coming
back as a stranger and landing in the spectator list.

**They are also put back on the table.** Rejoining used to reclaim the seat and
then leave the client sitting on the team picker while the game carried on
without it: the only thing the server sent was a game snapshot, and the lobby
scene does not listen for those. The server now works out what a peer arriving
after the lobby needs (`_room_entry_for`) and sends it - the dealer-draw screen
if the dealer is still being picked, otherwise the match setup **and** the
current state - so the client lands where the game actually is.

The answer can arrive before the lobby scene has finished loading, which would
fire the signal into nothing. `NetworkManager` keeps the last entry in
`pending_game_entry` and the lobby picks it up on `_ready` if it is already
waiting, so the timing cannot lose it.

### Two clients on one machine (tested)

They share `user://`, so they would share that saved id, and the second one
would look like the first one reconnecting and take its seat. The server now
refuses to hand over a seat whose player is still connected on a different
live connection, and tells that client to mint a fresh id and rejoin as a new
player. Once the first client really has gone, the id works normally again.

### Someone joins mid-game (tested)

**Not allowed into a seat, ever.** Seats and hands are fixed when the deal
starts, so a newcomer becomes a spectator (their view is redacted - no hands, no
hidden trump). This holds even if a seat is technically free because bots were
turned off; dealing them in halfway through is not possible.

If the room has spectators disabled they are refused with a message rather than
silently ignored, and the message now says which it is - the game has started,
or the room is full.

### Watching (tested)

Spectating used to exist only as a room flag: "Allow spectators" decided whether
a full or running room would accept a watcher, but nothing in the UI could ask
to be one, and anybody who did become one was parked in the lobby forever.

- **Getting in:** the online menu has a **Watch Instead** button next to Join.
  It joins with `as_spectator = true`, so it works on a room that has not
  started yet as well as one already playing.
- **Waiting:** a watcher who arrives before the start sits in the lobby with the
  seat controls hidden and a line saying they are watching. Players see a
  "(N watching)" count on their hint line.
- **Getting to the table:** spectators are included in the lobby, dealer-draw
  and match-start broadcasts, so the game opens for them at the same moment it
  opens for everybody else.
- **What they see:** every hand is redacted, *including the seat drawn at the
  bottom of their own screen*, which belongs to a real player. That seat is
  capped and face down like any other, is not clickable, and is named rather
  than called "You". `is_host` and `must_play_trump` are forced off so a
  watcher can never inherit the rematch button or somebody else's obligation.
- **The screen:** a WATCHING badge, no action buttons, no trump-mode dialog, no
  turn ring for a turn they do not have, and the scoreboard names the two sides
  ("TEAM A" / "TEAM B") instead of "your team" / "opponents". A court still gets
  its full banner and confetti with the winning side named.

### The host leaves (tested)

The host used to be "the first player in the list", so if they dropped, their
`peer_id` went to -1 and **nobody could start a match or a rematch again**. The
host role now passes to the first player who is actually connected.

### Bots off and the table is short (tested)

The Start button used to do nothing at all, with no explanation. The server now
sends back "Need 4 players to start (2 here). Turn on bots or wait for more
players", shown on the lobby's hint line. A full table with bots off starts
normally. A non-host still cannot start the match.

### Everybody leaves (tested)

Rooms used to leak: disconnected players still counted as human, so a room with
nobody in it stayed in memory forever. A room with no connected players and no
spectators is now marked empty and closed after a 3-minute grace period, which
is long enough for a dropped connection to come back to its seat.

### Smaller things

- The server no longer sends RPCs to `peer_id = -1` (a disconnected player),
  which was producing a stream of "unknown peer ID" errors on every broadcast.
- Leaving is now behind a confirmation dialog, because it is easy to hit by
  accident mid-hand and cannot be undone from the other players' side.
- A disconnect mid-turn immediately re-arms the turn logic rather than waiting
  for the next broadcast.
- Joining a room code that does not exist used to return in silence, which on
  the client was indistinguishable from a dead button. It now answers with
  "No room with code XXXXX", and the online menu shows join errors at all -
  it never listened for them before.

## Not handled, and why

### The client does not reconnect by itself

If the connection drops, the game screen says "Connection lost" and you have to
leave and rejoin with the room code. The seat and the identity are both waiting
for you, so rejoining works - but it is manual.

**Best fix:** a retry loop in `NetworkManager` that re-dials the server a few
times with backoff and rejoins the room automatically, with a "Reconnecting…"
overlay. It is the single highest-value remaining item, and it is contained -
the server side already supports it.

### The server restarting loses every room

Rooms live in memory. A Render deploy or a crash drops every game in progress.

**Best fix:** for a hobby deployment, do not fix this - persisting match state
to a database is a large change for a rare event. Deploy between sessions.

### A player who leaves a running game still holds their seat

Leaving mid-match is still treated as dropping out: the seat is held for 3
minutes even though they chose to go. That is deliberate - the hand is dealt and
nobody else can be given it - but it does mean a table cannot be freed up early.

**Best fix:** open the seat at the end of the current game rather than
immediately, so a spectator could take it between deals. Worth doing together
with spectator-to-player promotion below; neither is much use alone.

### A spectator cannot be promoted into a free seat

Watching is now a complete path in and out, but a spectator stays a spectator
for the life of the room. If a player leaves for good, their seat is played by
the server rather than offered to whoever is watching.

**Best fix:** pair it with the deliberate-leave item above - a Leave that tells
the server it means it, and a "take this seat" prompt for spectators between
games. Mid-game promotion is not possible: there is no hand to hand over.

### Free-tier hosting sleeps

Render's free tier sleeps when idle and takes 30-60 s to wake. The client
already allows a 90-second handshake, so the first connection of the day is
slow but works. Nothing to fix, just something to know.

### Bots never open the hidden trump

Bots follow suit and play legally, but they will not choose to reveal a closed
trump when void. It is a legal choice not to, so this is not a bug - but a bot
holding a strong trump plays worse than a human would.

**Best fix:** reveal when void in the lead suit and holding a high trump.
Small, self-contained, and only touches `_choose_bot_card`.
