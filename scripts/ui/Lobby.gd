extends Control

@onready var room_code_label: Label = %RoomCodeLabel
@onready var copy_code_button: Button = %CopyCodeButton
@onready var team_a_header: Label = %TeamAHeader
@onready var team_b_header: Label = %TeamBHeader
@onready var team_a_list: VBoxContainer = %TeamAList
@onready var team_b_list: VBoxContainer = %TeamBList
@onready var join_team_a_button: Button = %JoinTeamAButton
@onready var join_team_b_button: Button = %JoinTeamBButton
@onready var hint_label: Label = %HintLabel
@onready var ready_button: Button = %ReadyButton
@onready var start_game_button: Button = %StartGameButton
@onready var leave_button: Button = %LeaveButton

const TEAM_A_COLOR := Color(0.463, 0.831, 0.6)
const TEAM_B_COLOR := Color(0.949, 0.706, 0.435)
const MUTED_COLOR := Color(0.604, 0.702, 0.647)

var players: Array = []
var settings: Dictionary = {}
var is_ready: bool = false

func _ready() -> void:
	ready_button.pressed.connect(_on_ready_pressed)
	start_game_button.pressed.connect(_on_start_game_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	copy_code_button.pressed.connect(_on_copy_code_pressed)
	join_team_a_button.pressed.connect(func(): _on_join_team_pressed("A"))
	join_team_b_button.pressed.connect(func(): _on_join_team_pressed("B"))

	room_code_label.text = NetworkManager.current_room_code

	NetworkManager.lobby_updated.connect(_on_lobby_updated)
	NetworkManager.start_match.connect(_on_start_match)
	NetworkManager.dealer_draw_updated.connect(_on_dealer_draw_updated)
	NetworkManager.trump_mode_choice_requested.connect(_on_trump_mode_choice_requested)
	NetworkManager.disconnected_from_server.connect(_on_server_disconnected)
	NetworkManager.room_error.connect(_on_room_error)

	if NetworkManager.current_lobby_players.size() > 0:
		players = NetworkManager.current_lobby_players.duplicate(true)
	settings = NetworkManager.current_room_settings.duplicate(true)
	_refresh_players()

	# Joining a room that is already playing gets an answer immediately, which
	# can arrive before this scene exists - the signal would fire into nothing
	# and leave the player staring at the team picker. Pick up anything that
	# landed early instead of waiting for a signal that has already gone.
	if not NetworkManager.pending_game_entry.is_empty():
		_enter_game(NetworkManager.pending_game_entry)

func _on_copy_code_pressed() -> void:
	DisplayServer.clipboard_set(NetworkManager.current_room_code)
	copy_code_button.text = "Copied!"
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(copy_code_button):
		copy_code_button.text = "Copy Code"

func _player_count() -> int:
	var count := int(settings.get("player_count", 4))
	if count == 4 or count == 6 or count == 8:
		return count
	return 4

func _team_capacity() -> int:
	return int(_player_count() / 2)

func _team_of(player: Dictionary) -> String:
	# Teams follow the seat the server handed out; the team choice only decides
	# which seat that is.
	var seat_id := str(player.get("seat_id", ""))
	if not seat_id.begins_with("seat_"):
		return ""
	return "A" if int(seat_id.trim_prefix("seat_")) % 2 == 0 else "B"

func _local_team() -> String:
	for p_raw in players:
		var p: Dictionary = p_raw
		if str(p.get("id", "")) == NetworkManager.local_player_id:
			return _team_of(p)
	return ""

func _members_of(team: String) -> Array:
	var out: Array = []
	for p_raw in players:
		var p: Dictionary = p_raw
		if _team_of(p) == team:
			out.append(p)
	return out

func _fill_team_column(list: VBoxContainer, team: String, color: Color) -> void:
	for child in list.get_children():
		child.queue_free()

	var members := _members_of(team)
	var host_id := "" if players.is_empty() else str((players[0] as Dictionary).get("id", ""))

	for p_raw in members:
		var p: Dictionary = p_raw
		var line := str(p.get("name", "Player"))
		if str(p.get("id", "")) == NetworkManager.local_player_id:
			line = "► " + line
		if str(p.get("id", "")) == host_id:
			line += "  ★"
		if bool(p.get("ready", false)):
			line += "  ✓"
		if not bool(p.get("is_connected", true)):
			line += "  (offline)"

		var row := Label.new()
		row.text = line
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_theme_font_size_override("font_size", 14)
		row.add_theme_color_override("font_color", color)
		list.add_child(row)

	# Empty seats read as "Bot" so the table composition is obvious up front.
	for _i in range(_team_capacity() - members.size()):
		var slot := Label.new()
		slot.text = "Bot"
		slot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot.add_theme_font_size_override("font_size", 14)
		slot.add_theme_color_override("font_color", MUTED_COLOR)
		list.add_child(slot)

func _refresh_players() -> void:
	_fill_team_column(team_a_list, "A", TEAM_A_COLOR)
	_fill_team_column(team_b_list, "B", TEAM_B_COLOR)

	var capacity := _team_capacity()
	team_a_header.text = "TEAM A   %d/%d" % [_members_of("A").size(), capacity]
	team_b_header.text = "TEAM B   %d/%d" % [_members_of("B").size(), capacity]

	# A watcher has no seat, so the seat controls would do nothing at all if
	# they were pressed. Hide them and say plainly what is going on instead.
	var watching := NetworkManager.is_spectator
	join_team_a_button.visible = not watching
	join_team_b_button.visible = not watching
	ready_button.visible = not watching
	start_game_button.visible = _is_local_host() and not watching

	if watching:
		hint_label.visible = true
		hint_label.text = "You are watching this room. The table opens as soon as the host starts."
		return

	var my_team := _local_team()
	join_team_a_button.text = "You're in A" if my_team == "A" else "Join A"
	join_team_b_button.text = "You're in B" if my_team == "B" else "Join B"
	join_team_a_button.disabled = my_team == "A" or _members_of("A").size() >= capacity
	join_team_b_button.disabled = my_team == "B" or _members_of("B").size() >= capacity

	hint_label.visible = not _is_local_host() or players.size() < 2 or _watcher_count() > 0
	hint_label.text = _default_hint()

func _watcher_count() -> int:
	return int(settings.get("spectator_count", 0))

func _default_hint() -> String:
	var base := "Pick a side before the host starts. Empty seats are filled with bots."
	var watchers := _watcher_count()
	if watchers == 1:
		return base + "  (1 watching)"
	if watchers > 1:
		return base + "  (%d watching)" % watchers
	return base

func _on_join_team_pressed(team: String) -> void:
	NetworkManager.send_team_choice(team)

func _on_room_error(message: String) -> void:
	# The server refused something (a short table, a full room). Say so on the
	# hint line rather than letting the button look broken.
	hint_label.visible = true
	hint_label.text = message
	hint_label.add_theme_color_override("font_color", Color(0.95, 0.42, 0.40))
	await get_tree().create_timer(6.0).timeout
	if is_instance_valid(hint_label):
		hint_label.remove_theme_color_override("font_color")
		hint_label.text = _default_hint()
		_refresh_players()

func _is_local_host() -> bool:
	if players.is_empty():
		return false

	for p_raw in players:
		var p: Dictionary = p_raw
		if str(p.get("id", "")) == NetworkManager.local_player_id:
			return int(p.get("peer_id", -1)) == int(players[0].get("peer_id", -2))

	return false

func _on_ready_pressed() -> void:
	is_ready = not is_ready
	ready_button.text = "Ready ✓" if is_ready else "Ready"
	NetworkManager.send_ready_state(is_ready)

func _on_start_game_pressed() -> void:
	NetworkManager.request_start_match()

func _on_leave_pressed() -> void:
	leave_button.disabled = true
	await NetworkManager.leave_room()
	get_tree().change_scene_to_file("res://scenes/ui/OnlineMenu.tscn")

func _on_server_disconnected() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

func _on_lobby_updated(updated_players: Array, updated_settings: Dictionary = {}) -> void:
	players = updated_players.duplicate(true)
	if not updated_settings.is_empty():
		settings = updated_settings.duplicate(true)
	_refresh_players()

func _mark_local_players(match_players: Array) -> Array:
	var players_copy: Array = match_players.duplicate(true)
	for i in range(players_copy.size()):
		var p: Dictionary = players_copy[i]
		p["is_local"] = (str(p.get("id", "")) == NetworkManager.local_player_id)
		players_copy[i] = p
	return players_copy

func _save_match_setup(setup: Dictionary) -> void:
	# In memory, not on disk: user:// is shared by every client running on
	# the same machine, which would give both players the same seat.
	NetworkManager.pending_match_setup = setup.duplicate(true)

func _enter_game(entry: Dictionary) -> void:
	# One door into the table, whether the host just started, the dealer draw
	# opened, or this client rejoined a game already in progress.
	NetworkManager.pending_game_entry = {}
	var data: Dictionary = entry.get("data", {})
	var kind := str(entry.get("kind", ""))
	var watching := bool(data.get("is_spectator", NetworkManager.is_spectator))

	var setup := {
		"players": _mark_local_players(data.get("players", [])),
		"phase": data.get("phase", "dealer_draw"),
		"dealer_draw_cards": data.get("dealer_draw_cards", []),
		"dealer_seat_id": data.get("dealer_seat_id", ""),
		"trump_holder_seat_id": data.get("trump_holder_seat_id", ""),
		"trump_mode": data.get("trump_mode", ""),
		"is_spectator": watching,
		"is_host": false
	}
	if kind == "start_match":
		setup["phase"] = data.get("phase", "server_match")
		setup["is_host"] = not watching and multiplayer.get_unique_id() == int(data.get("host_peer_id", -1))

	_save_match_setup(setup)
	get_tree().change_scene_to_file("res://scenes/game/GameRoom3D.tscn")

func _on_start_match(match_setup: Dictionary) -> void:
	_enter_game({"kind": "start_match", "data": match_setup})

func _on_dealer_draw_updated(match_data: Dictionary) -> void:
	_enter_game({"kind": "dealer_draw", "data": match_data})

func _on_trump_mode_choice_requested(match_data: Dictionary) -> void:
	_enter_game({"kind": "trump_mode_choice", "data": match_data})
