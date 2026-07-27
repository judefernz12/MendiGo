extends SceneTree

# What happens when things go wrong: someone drops out, someone tries to join a
# game already in progress, two clients on one machine share a saved identity,
# the host leaves, the table is short and bots are off.
#
# Each case is driven against the real Server.gd.

const ServerScript = preload("res://scripts/game/Server.gd")

var server: Node
var sink: Node
var fails: Array = []
var checks := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		fails.append(label)
		print("  FAIL: ", label)

func room(code: String) -> Dictionary:
	return server.rooms.get(code, {})

func player_in(code: String, player_id: String) -> Dictionary:
	for p in room(code).get("players", []):
		if str(p.get("id", "")) == player_id:
			return p
	return {}

func make_room(settings: Dictionary) -> String:
	server._server_create_room({"id": "host", "name": "Host"}, settings, 10)
	for key in server.rooms.keys():
		if str(server.rooms[key].get("players", [])[0].get("id", "")) == "host":
			return str(key)
	return ""

func _initialize() -> void:
	_run()

func _run() -> void:
	sink = Node.new()
	sink.name = "TestSink"
	root.add_child(sink)
	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	drop_out_check()
	lobby_leave_check()
	mid_match_leave_check()
	mid_game_join_check()
	rejoin_entry_check()
	spectator_check()
	spectators_disabled_check()
	identity_conflict_check()
	host_handover_check()
	short_table_check()
	empty_room_check()

	_report()

# --- a player drops out mid-match -----------------------------------------

func drop_out_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 11)
	server._server_start_match(code, "host", 10)
	ok(room(code).get("players", []).size() == 4, "bots fill the table on start")

	var guest_seat := str(player_in(code, "guest").get("seat_id", ""))
	server._on_peer_disconnected(11)

	var guest := player_in(code, "guest")
	ok(not guest.is_empty(), "a player who drops out keeps their place in the room")
	ok(not bool(guest.get("is_connected", true)), "they are marked as disconnected")
	ok(str(guest.get("seat_id", "")) == guest_seat, "their seat is held for them")
	ok(server.rooms.has(code), "the room survives a player dropping out")

	# The server has to play for them, and quickly: waiting out the full turn
	# deadline on every one of their turns would stall the whole table.
	ok(server._seat_is_absent(room(code), guest_seat), "the empty seat is recognised as absent")
	ok(server._seat_is_auto(room(code), guest_seat), "the server takes over the empty seat")
	ok(not server._seat_is_auto(room(code), str(player_in(code, "host").get("seat_id", ""))), "a connected player is still played by hand")

	# Coming back reclaims the seat and the state.
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 12)
	var back := player_in(code, "guest")
	ok(bool(back.get("is_connected", false)), "reconnecting marks the player present again")
	ok(int(back.get("peer_id", -1)) == 12, "reconnecting attaches the new connection")
	ok(str(back.get("seat_id", "")) == guest_seat, "reconnecting returns to the same seat")
	ok(not server._seat_is_auto(room(code), guest_seat), "the server hands the seat back")
	server.rooms.clear()

# --- leaving from the lobby -------------------------------------------------

func lobby_leave_check() -> void:
	# In the lobby there is no hand to come back to, so a seat held for a
	# leaver is just a ghost: the room reads as fuller than it is, and the
	# leaver's own rejoin collides with its stale entry.
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 11)
	ok(room(code).get("players", []).size() == 2, "two players are in the room")

	server._server_leave_room(code, "guest", 11)
	ok(player_in(code, "guest").is_empty(), "leaving the lobby removes the player, not just their connection")
	ok(room(code).get("players", []).size() == 1, "the room shrinks back")
	ok(not server.peer_to_room.has(11), "their connection is no longer tied to the room")

	# The whole point: they can come straight back under the same name.
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 12)
	var back := player_in(code, "guest")
	ok(not back.is_empty(), "they can rejoin the same room afterwards")
	ok(int(back.get("peer_id", -1)) == 12, "on their new connection")
	ok(room(code).get("players", []).size() == 2, "and are counted once, not twice")

	# A close that arrives with no warning must behave the same way.
	server._on_peer_disconnected(12)
	ok(player_in(code, "guest").is_empty(), "closing the tab in the lobby also removes the player")

	# Seats stay coherent: whoever is left keeps a real, unique seat.
	server._server_join_room(code, {"id": "a", "name": "A"}, false, 13)
	server._server_join_room(code, {"id": "b", "name": "B"}, false, 14)
	server._server_leave_room(code, "a", 13)
	var seats := {}
	for p_raw in room(code).get("players", []):
		var p: Dictionary = p_raw
		seats[str(p.get("seat_id", ""))] = true
	ok(seats.size() == room(code).get("players", []).size(), "the remaining players hold distinct seats")
	ok(not seats.has(""), "and none of them is left without one")

	# Nobody may throw anybody else out.
	server._server_leave_room(code, "host", 14)
	ok(not player_in(code, "host").is_empty(), "a player cannot remove somebody else from the room")
	ok(not player_in(code, "b").is_empty(), "and the impostor is not removed either")

	# The host leaving hands the room over rather than orphaning it.
	server._server_leave_room(code, "host", 10)
	ok(player_in(code, "host").is_empty(), "the host can leave the lobby too")
	ok(server._get_room_host_peer(room(code)) == 14, "the next player inherits the room")

	# The reported symptom: leave, re-dial and rejoin, all faster than a
	# WebSocket teardown crossing the internet. If the client says nothing, the
	# room still holds a live entry under that id and refuses the rejoin as a
	# second window - so the client is told the name is taken.
	server.rooms.clear()
	var race := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(race, {"id": "quick", "name": "Quick"}, false, 21)
	server._server_leave_room(race, "quick", 21)
	server._server_join_room(race, {"id": "quick", "name": "Quick"}, false, 22)
	ok(int(player_in(race, "quick").get("peer_id", -1)) == 22, "leaving and rejoining at once is not mistaken for a second window")
	ok(room(race).get("players", []).size() == 2, "and leaves no ghost behind")
	server.rooms.clear()

func mid_match_leave_check() -> void:
	# Mid-match is the opposite case: the cards are dealt, so the seat has to
	# be held even for a deliberate leave.
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 11)
	server._server_start_match(code, "host", 10)
	var guest_seat := str(player_in(code, "guest").get("seat_id", ""))

	server._server_leave_room(code, "guest", 11)
	var guest := player_in(code, "guest")
	ok(not guest.is_empty(), "leaving a running game still holds the seat")
	ok(not bool(guest.get("is_connected", true)), "but marks them away")
	ok(str(guest.get("seat_id", "")) == guest_seat, "on the same seat, so they can come back to their hand")
	ok(server._seat_is_auto(room(code), guest_seat), "and the server plays it meanwhile")
	server.rooms.clear()

# --- joining a game already in progress ------------------------------------

func mid_game_join_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true, "spectators_enabled": true})
	server._server_start_match(code, "host", 10)
	var before: int = room(code).get("players", []).size()

	server._server_join_room(code, {"id": "latecomer", "name": "Late"}, false, 20)
	ok(room(code).get("players", []).size() == before, "a latecomer is not given a seat mid-game")
	ok(player_in(code, "latecomer").is_empty(), "a latecomer does not appear among the players")
	var spectators: Array = room(code).get("spectators", [])
	ok(spectators.size() == 1, "a latecomer becomes a spectator instead")
	ok(str(spectators[0].get("id", "")) == "latecomer", "the spectator is the latecomer")

	# Even with a free seat, joining mid-game must not deal them in.
	server.rooms.clear()
	var code2 := make_room({"player_count": 6, "target_score": 15, "bots_enabled": false, "spectators_enabled": true})
	server._server_join_room(code2, {"id": "p2", "name": "P2"}, false, 21)
	var room2: Dictionary = server.rooms[code2]
	room2["phase"] = "dealer_draw"
	server.rooms[code2] = room2
	server._server_join_room(code2, {"id": "p3", "name": "P3"}, false, 22)
	ok(player_in(code2, "p3").is_empty(), "a free seat is still not handed out once the match has started")
	ok((room(code2).get("spectators", []) as Array).size() == 1, "they watch instead")
	server.rooms.clear()

# --- what a client is sent when it arrives after the lobby -----------------

func start_playing(code: String) -> void:
	# Skips the dealer draw and puts the room into a real match.
	var r: Dictionary = room(code)
	r["phase"] = "match"
	r["match_state"] = server._deal_remaining_cards(server._create_match_state(r))
	server.rooms[code] = r

func rejoin_entry_check() -> void:
	# The bug: rejoining a running game landed on the team picker and stayed
	# there, because the only thing sent was a snapshot the lobby ignores.
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true, "spectators_enabled": true})
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 11)

	ok(server._room_entry_for(room(code), 11, false).is_empty(), "a player in a lobby belongs in the lobby")

	server._server_start_match(code, "host", 10)
	var draw_entry: Dictionary = server._room_entry_for(room(code), 11, false)
	ok(str(draw_entry.get("method", "")) == "_client_dealer_draw_updated", "rejoining during the dealer draw opens the draw screen")
	ok(not draw_entry.has("snapshot"), "there is no game state to hand over yet")

	var guest_seat := str(player_in(code, "guest").get("seat_id", ""))
	start_playing(code)

	var entry: Dictionary = server._room_entry_for(room(code), 11, false)
	ok(str(entry.get("method", "")) == "_client_start_match", "rejoining a running game is sent to the table, not the lobby")
	ok(entry.has("snapshot"), "and is handed the current state along with it")

	var setup: Dictionary = entry.get("payload", {})
	ok(not bool(setup.get("is_spectator", true)), "a returning player comes back as a player")
	ok((setup.get("players", []) as Array).size() == 4, "the setup carries the whole table")

	var gs: Dictionary = (entry.get("snapshot", {}) as Dictionary).get("game_state", {})
	var my_info: Dictionary = (gs.get("seat_info", {}) as Dictionary).get("my", {})
	ok(str(my_info.get("seat_id", "")) == guest_seat, "the state is built for their own seat")
	ok(not (gs.get("hands", {}) as Dictionary).get("my", []).is_empty(), "their own hand comes back with them")
	server.rooms.clear()

# --- watching --------------------------------------------------------------

func spectator_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true, "spectators_enabled": true})

	# Asking to watch a room that has not started yet is allowed: no seat taken.
	server._server_join_room(code, {"id": "watcher", "name": "Watcher"}, true, 40)
	ok(player_in(code, "watcher").is_empty(), "a watcher never takes a seat")
	ok((room(code).get("spectators", []) as Array).size() == 1, "a watcher is recorded as a spectator")
	ok(str(server.peer_to_room.get(40, "")) == code, "the watcher's connection is tied to the room")
	ok(server._room_entry_for(room(code), 40, true).is_empty(), "a watcher waits in the lobby until the game starts")

	server._server_start_match(code, "host", 10)
	var draw: Dictionary = server._room_entry_for(room(code), 40, true)
	ok(str(draw.get("method", "")) == "_client_dealer_draw_updated", "a watcher is taken to the table when the match starts")
	ok(bool((draw.get("payload", {}) as Dictionary).get("is_spectator", false)), "and is told they are watching")

	start_playing(code)
	var entry: Dictionary = server._room_entry_for(room(code), 40, true)
	ok(str(entry.get("method", "")) == "_client_start_match", "a watcher joining a running game opens the table")
	ok(bool((entry.get("payload", {}) as Dictionary).get("is_spectator", false)), "the setup marks them as a watcher")

	var gs: Dictionary = (entry.get("snapshot", {}) as Dictionary).get("game_state", {})
	ok(bool(gs.get("is_spectator", false)), "the snapshot marks them as a watcher")
	ok(not bool(gs.get("is_host", true)), "a watcher never inherits the rematch button")
	ok(not bool(gs.get("must_play_trump", true)), "nor anybody else's obligation to play a trump")

	# Nothing in any hand may be readable - including the seat the client draws
	# at the bottom of its own screen, which belongs to a real player.
	var hands: Dictionary = gs.get("hands", {})
	var faces_up := 0
	var real_ranks := 0
	for view in hands.keys():
		for c_raw in hands[view]:
			var c: Dictionary = c_raw
			if bool(c.get("is_face_up", false)):
				faces_up += 1
			if int(c.get("id", 0)) != 0:
				real_ranks += 1
	ok(not (hands.get("my", []) as Array).is_empty(), "a watcher still sees how many cards each seat holds")
	ok(faces_up == 0, "no hand is face up for a watcher, the bottom seat included")
	ok(real_ranks == 0, "and no card carries its real identity")
	server.rooms.clear()

func spectators_disabled_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true, "spectators_enabled": false})
	server._server_start_match(code, "host", 10)

	server._server_join_room(code, {"id": "watcher", "name": "Watcher"}, true, 41)
	ok((room(code).get("spectators", []) as Array).is_empty(), "a room with spectators off takes none")
	ok(player_in(code, "watcher").is_empty(), "and does not seat them either")
	ok(not server.peer_to_room.has(41), "the refused connection is not attached to the room")
	server.rooms.clear()

# --- two clients on one machine sharing a saved identity --------------------

func identity_conflict_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "twin", "name": "Twin"}, false, 30)
	ok(not player_in(code, "twin").is_empty(), "the first client takes the seat")
	var first_peer := int(player_in(code, "twin").get("peer_id", -1))

	# A second, still-connected client claiming the same id must not take over.
	server._server_join_room(code, {"id": "twin", "name": "Twin"}, false, 31)
	ok(int(player_in(code, "twin").get("peer_id", -1)) == first_peer, "a live seat cannot be stolen by the same id")
	ok(room(code).get("players", []).size() == 2, "the second client is not seated as well")

	# Once the first one really has gone, the id works again.
	server._on_peer_disconnected(first_peer)
	server._server_join_room(code, {"id": "twin", "name": "Twin"}, false, 32)
	ok(int(player_in(code, "twin").get("peer_id", -1)) == 32, "the id reclaims its seat once the first client is gone")
	server.rooms.clear()

# --- the host leaves --------------------------------------------------------

func host_handover_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "second", "name": "Second"}, false, 11)
	ok(server._get_room_host_peer(room(code)) == 10, "the room starts with its creator as host")

	server._on_peer_disconnected(10)
	ok(server._get_room_host_peer(room(code)) == 11, "the next connected player inherits the host role")

	# And that new host can actually start the match.
	server._server_start_match(code, "second", 11)
	ok(str(room(code).get("phase", "")) == "dealer_draw", "the new host can start the match")
	server.rooms.clear()

# --- bots off and not enough players ---------------------------------------

func short_table_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": false})
	server._server_join_room(code, {"id": "second", "name": "Second"}, false, 11)

	server._server_start_match(code, "host", 10)
	ok(str(room(code).get("phase", "lobby")) == "lobby", "a short table with bots off does not start")
	ok(room(code).get("players", []).size() == 2, "no bots are added when bots are off")

	# Fill it and it starts.
	server._server_join_room(code, {"id": "third", "name": "Third"}, false, 12)
	server._server_join_room(code, {"id": "fourth", "name": "Fourth"}, false, 13)
	server._server_start_match(code, "host", 10)
	ok(str(room(code).get("phase", "")) == "dealer_draw", "a full table with bots off does start")

	# A non-host cannot start it either way.
	server.rooms.clear()
	var code2 := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code2, {"id": "second", "name": "Second"}, false, 11)
	server._server_start_match(code2, "second", 11)
	ok(str(room(code2).get("phase", "lobby")) == "lobby", "a non-host cannot start the match")
	server.rooms.clear()

# --- everybody leaves -------------------------------------------------------

func empty_room_check() -> void:
	server.rooms.clear()
	var code := make_room({"player_count": 4, "target_score": 15, "bots_enabled": true})
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 11)
	server._server_start_match(code, "host", 10)

	server._on_peer_disconnected(10)
	ok(server.rooms.has(code), "the room stays open while someone is still connected")
	ok(server._connected_humans(room(code)) == 1, "one player is still counted as present")

	server._on_peer_disconnected(11)
	ok(server.rooms.has(code), "the room is held open briefly after the last player drops")
	ok(server._connected_humans(room(code)) == 0, "nobody is counted as present")
	ok(room(code).has("empty_since_ms"), "the room is marked as empty and awaiting cleanup")

	# Coming back inside the grace period keeps the room alive.
	server._server_join_room(code, {"id": "guest", "name": "Guest"}, false, 14)
	ok(not room(code).has("empty_since_ms"), "reconnecting cancels the pending cleanup")
	ok(server._connected_humans(room(code)) == 1, "the returning player is counted again")
	server.rooms.clear()

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_RESILIENCE_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
