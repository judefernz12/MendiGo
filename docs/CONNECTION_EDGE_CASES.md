# What happens when things go wrong

Every case below was checked against the real `Server.gd`. The ones marked
(tested) are covered by `tests/resilience_test.gd`; run it and it will tell you
if any of this stops being true.

## Handled

### A player leaves or their connection drops mid-match (tested)

Their seat is **held**, not freed. They stay in the room marked
`is_connected = false`, and the server plays their hand for them.

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

### Two clients on one machine (tested)

They share `user://`, so they would share that saved id, and the second one
would look like the first one reconnecting and take its seat. The server now
refuses to hand over a seat whose player is still connected on a different
live connection, and tells that client to mint a fresh id and rejoin as a new
player. Once the first client really has gone, the id works normally again.

### Someone joins mid-game (tested)

**Not allowed into a seat.** Seats and hands are fixed when the deal starts, so
a newcomer becomes a spectator (their view is redacted - no hands, no hidden
trump). This holds even if a seat is technically free because bots were turned
off; dealing them in halfway through is not possible.

If the room has spectators disabled they are refused with a message rather than
silently ignored.

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

### A player who leaves deliberately still holds their seat

Leaving via the button is treated the same as dropping out, so the seat is held
for 3 minutes even though they chose to go.

**Best fix:** have the Leave button tell the server it is deliberate, so the
seat opens for a spectator to take. Worth doing once spectator-to-player
promotion exists; the two features only make sense together.

### No spectator UI

Spectators receive correctly redacted snapshots and can watch, but there is no
"you are watching" banner and no way to be promoted into a free seat.

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
