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
	mid_game_join_check()
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
