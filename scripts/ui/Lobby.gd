extends Control

@onready var room_code_label: Label = %RoomCodeLabel
@onready var copy_code_button: Button = %CopyCodeButton
@onready var player_list: VBoxContainer = %PlayerList
@onready var hint_label: Label = %HintLabel
@onready var ready_button: Button = %ReadyButton
@onready var start_game_button: Button = %StartGameButton
@onready var leave_button: Button = %LeaveButton

var players: Array = []
var is_ready: bool = false

func _ready() -> void:
	ready_button.pressed.connect(_on_ready_pressed)
	start_game_button.pressed.connect(_on_start_game_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	copy_code_button.pressed.connect(_on_copy_code_pressed)

	room_code_label.text = NetworkManager.current_room_code

	NetworkManager.lobby_updated.connect(_on_lobby_updated)
	NetworkManager.start_match.connect(_on_start_match)
	NetworkManager.dealer_draw_updated.connect(_on_dealer_draw_updated)
	NetworkManager.trump_mode_choice_requested.connect(_on_trump_mode_choice_requested)
	NetworkManager.disconnected_from_server.connect(_on_server_disconnected)

	if NetworkManager.current_lobby_players.size() > 0:
		players = NetworkManager.current_lobby_players.duplicate(true)
	_refresh_players()

func _on_copy_code_pressed() -> void:
	DisplayServer.clipboard_set(NetworkManager.current_room_code)
	copy_code_button.text = "Copied!"
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(copy_code_button):
		copy_code_button.text = "Copy Code"

func _refresh_players() -> void:
	for child in player_list.get_children():
		child.queue_free()

	if players.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Waiting for players..."
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		player_list.add_child(empty_label)
	else:
		for i in range(players.size()):
			var p: Dictionary = players[i]
			var line := "%d.  %s" % [i + 1, str(p.get("name", "Player"))]
			if i == 0:
				line += "  (host)"
			if bool(p.get("ready", false)):
				line += "  ✓"
			if not bool(p.get("is_connected", true)):
				line += "  [offline]"

			var row := Label.new()
			row.text = line
			row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			player_list.add_child(row)

	start_game_button.visible = _is_local_host()
	hint_label.visible = not _is_local_host() or players.size() < 2

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
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/ui/OnlineMenu.tscn")

func _on_server_disconnected() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

func _on_lobby_updated(updated_players: Array) -> void:
	players = updated_players.duplicate(true)
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

func _on_start_match(match_setup: Dictionary) -> void:
	var host_peer_id: int = int(match_setup.get("host_peer_id", -1))
	match_setup["players"] = _mark_local_players(match_setup.get("players", []))
	match_setup["is_host"] = (multiplayer.get_unique_id() == host_peer_id)

	_save_match_setup(match_setup)
	get_tree().change_scene_to_file("res://scenes/game/GameRoom3D.tscn")

func _on_dealer_draw_updated(match_data: Dictionary) -> void:
	var setup := {
		"players": _mark_local_players(match_data.get("players", [])),
		"phase": match_data.get("phase", "dealer_draw"),
		"dealer_draw_cards": match_data.get("dealer_draw_cards", []),
		"dealer_seat_id": match_data.get("dealer_seat_id", ""),
		"trump_holder_seat_id": match_data.get("trump_holder_seat_id", ""),
		"trump_mode": match_data.get("trump_mode", ""),
		"is_host": false
	}

	_save_match_setup(setup)
	get_tree().change_scene_to_file("res://scenes/game/GameRoom3D.tscn")

func _on_trump_mode_choice_requested(match_data: Dictionary) -> void:
	var setup := {
		"players": _mark_local_players(match_data.get("players", [])),
		"phase": match_data.get("phase", "trump_mode_choice"),
		"dealer_draw_cards": match_data.get("dealer_draw_cards", []),
		"dealer_seat_id": match_data.get("dealer_seat_id", ""),
		"trump_holder_seat_id": match_data.get("trump_holder_seat_id", ""),
		"trump_mode": match_data.get("trump_mode", ""),
		"is_host": false
	}

	_save_match_setup(setup)
	get_tree().change_scene_to_file("res://scenes/game/GameRoom3D.tscn")
