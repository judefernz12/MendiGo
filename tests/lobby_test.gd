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

	_report()

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
