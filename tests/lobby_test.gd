extends SceneTree

# Drives the real Lobby scene with real server output and checks the team
# picker: each side must list the right players, empty seats must read as bots,
# and the join buttons must reflect where the local player actually sits.

const ServerScript = preload("res://scripts/game/Server.gd")

var server: Node
var net: Node
var lobby: Control
var code := ""
var fails: Array = []
var checks := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		fails.append(label)
		print("  FAIL: ", label)

func names_in(list: VBoxContainer) -> Array:
	var out: Array = []
	for child in list.get_children():
		if child is Label:
			out.append(str((child as Label).text))
	return out

func has_name(list: VBoxContainer, needle: String) -> bool:
	for text in names_in(list):
		if str(text).contains(needle):
			return true
	return false

func push_lobby() -> void:
	var room: Dictionary = server.rooms[code]
	lobby._on_lobby_updated(room.get("players", []), room.get("settings", {}))
	await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	net = root.get_node_or_null("NetworkManager")
	ok(net != null, "the NetworkManager autoload is available")
	if net == null:
		_report()
		return

	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	server._server_create_room({"id": "host_1", "name": "Ann"}, {
		"player_count": 4, "target_score": 15, "bots_enabled": true
	}, 2)
	code = str(server.rooms.keys()[0])
	server._server_join_room(code, {"id": "guest_1", "name": "Ben"}, false, 3)

	# Bring up the real lobby as the guest.
	net.local_player_id = "guest_1"
	net.local_player_name = "Ben"
	net.current_room_code = code
	net.current_lobby_players = server.rooms[code].get("players", [])
	net.current_room_settings = server.rooms[code].get("settings", {})

	var packed: PackedScene = load("res://scenes/ui/Lobby.tscn")
	lobby = packed.instantiate()
	root.add_child(lobby)
	await process_frame

	ok(str(lobby.room_code_label.text) == code, "the lobby shows the room code")
	ok(has_name(lobby.team_a_list, "Ann"), "the host is listed on team A")
	ok(has_name(lobby.team_b_list, "Ben"), "the guest is listed on team B")
	ok(has_name(lobby.team_a_list, "Bot") and has_name(lobby.team_b_list, "Bot"), "empty seats read as bots")
	ok(names_in(lobby.team_a_list).size() == 2 and names_in(lobby.team_b_list).size() == 2, "each side shows exactly half the table")
	ok(str(lobby.team_a_header.text).contains("1/2") and str(lobby.team_b_header.text).contains("1/2"), "each side shows how full it is")
	ok(lobby.join_team_b_button.disabled, "the side the player is already on cannot be joined again")
	ok(not lobby.join_team_a_button.disabled, "the other side can be joined")
	ok(str(lobby.join_team_b_button.text).contains("You're in"), "the button says which side the player is on")

	# The guest switches to team A: both humans must end up as partners.
	server._server_set_team(code, "guest_1", "A", 3)
	await push_lobby()

	ok(has_name(lobby.team_a_list, "Ann") and has_name(lobby.team_a_list, "Ben"), "both humans appear on the side they picked")
	ok(not has_name(lobby.team_b_list, "Ben"), "the guest is removed from the old side")
	ok(str(lobby.team_a_header.text).contains("2/2"), "a full side is shown as full")
	ok(lobby.join_team_a_button.disabled, "a joined side cannot be re-joined")
	ok(not lobby.join_team_b_button.disabled, "the free side stays joinable")

	# From the host's point of view the same room reads the same way.
	net.local_player_id = "host_1"
	await push_lobby()
	ok(lobby.join_team_a_button.disabled and not lobby.join_team_b_button.disabled, "the host also sees itself on the picked side")
	ok(lobby.start_game_button.visible, "only the host sees the start button")

	net.local_player_id = "guest_1"
	await push_lobby()
	ok(not lobby.start_game_button.visible, "a non-host does not see the start button")

	spectator_lobby_check()
	await process_frame
	entry_check()
	online_menu_check()

	_report()

# --- the way in ------------------------------------------------------------

func online_menu_check() -> void:
	# "Allow spectators" was a room flag with no way to take it up. Watching
	# needs its own door.
	net.use_local_server = true   # never dial the real server from a test
	var menu: Control = load("res://scenes/ui/OnlineMenu.tscn").instantiate()
	root.add_child(menu)

	ok(menu.watch_button != null, "the online menu offers a way to watch")
	if menu.watch_button == null:
		menu.queue_free()
		return
	ok(menu.watch_button.get_parent() == menu.join_by_code_button.get_parent(), "the watch button sits with the join controls")
	ok(menu.watch_button.get_index() == menu.join_by_code_button.get_index() + 1, "directly under Join")

	menu._on_connected_to_server()
	ok(not menu.watch_button.disabled, "watching is offered once connected")

	menu.room_code_input.text = ""
	menu._on_watch_pressed()
	ok(str(menu.status_label.text).to_lower().contains("code"), "watching without a room code asks for one")

	menu._on_disconnected_from_server()
	ok(menu.watch_button.disabled, "and is not offered with no connection")

	menu.queue_free()
	net.disconnect_from_server()   # drop the dial-out this test started

# --- watching from the lobby ------------------------------------------------

func spectator_lobby_check() -> void:
	# A watcher has no seat, so seat controls would silently do nothing. They
	# must not be offered at all.
	net.is_spectator = true
	lobby._refresh_players()

	ok(not lobby.join_team_a_button.visible and not lobby.join_team_b_button.visible, "a watcher is not offered the team buttons")
	ok(not lobby.ready_button.visible, "nor the ready button")
	ok(not lobby.start_game_button.visible, "nor the start button")
	ok(lobby.hint_label.visible and str(lobby.hint_label.text).to_lower().contains("watching"), "the lobby says plainly that they are watching")

	net.is_spectator = false
	lobby._refresh_players()
	ok(lobby.join_team_a_button.visible and lobby.ready_button.visible, "a seated player gets the controls back")

	# The room tells everyone how many people are watching.
	var settings: Dictionary = (server.rooms[code].get("settings", {}) as Dictionary).duplicate(true)
	settings["spectator_count"] = 2
	lobby._on_lobby_updated(server.rooms[code].get("players", []), settings)
	ok(str(lobby.hint_label.text).contains("2 watching"), "the lobby counts the watchers for the players")

# --- the entry that used to be dropped on the floor -------------------------

func entry_check() -> void:
	# Joining a running room is answered immediately, which can beat this scene
	# into existence. The lobby has to pick up an entry that already arrived
	# instead of waiting for a signal that has already fired.
	var players: Array = server.rooms[code].get("players", [])
	net.pending_game_entry = {
		"kind": "start_match",
		"data": {
			"players": players,
			"host_peer_id": 2,
			"phase": "server_match",
			"dealer_seat_id": "seat_0",
			"trump_holder_seat_id": "seat_1",
			"is_spectator": false
		}
	}

	var probe: Control = load("res://scenes/ui/Lobby.tscn").instantiate()
	root.add_child(probe)
	ok(net.pending_game_entry.is_empty(), "a lobby that opens onto a running game consumes the waiting entry")

	var setup: Dictionary = net.pending_match_setup
	ok(str(setup.get("phase", "")) == "server_match", "and hands the game scene the match it joined")
	ok((setup.get("players", []) as Array).size() == players.size(), "with the whole table")
	ok(str(setup.get("trump_holder_seat_id", "")) == "seat_1", "and who holds the trump")
	var marked := false
	for p_raw in setup.get("players", []):
		var p: Dictionary = p_raw
		if str(p.get("id", "")) == net.local_player_id:
			marked = bool(p.get("is_local", false))
	ok(marked, "the local player is marked in the handoff")
	probe.queue_free()

	# A watcher's handoff must never claim a seat or the host role.
	net.is_spectator = true
	net.pending_match_setup = {}
	net.pending_game_entry = {
		"kind": "start_match",
		"data": {"players": players, "host_peer_id": 2, "phase": "server_match", "is_spectator": true}
	}
	var watcher: Control = load("res://scenes/ui/Lobby.tscn").instantiate()
	root.add_child(watcher)
	ok(bool(net.pending_match_setup.get("is_spectator", false)), "a watcher is handed off as a watcher")
	ok(not bool(net.pending_match_setup.get("is_host", true)), "and never as the host, even on the host's own connection")
	watcher.queue_free()
	net.is_spectator = false

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_LOBBY_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
