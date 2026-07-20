extends Control

@onready var status_label: Label = %StatusLabel
@onready var retry_button: Button = %RetryButton
@onready var settings_grid: GridContainer = %SettingsGrid
@onready var settings_box: VBoxContainer = %SettingsBox
@onready var create_room_button: Button = %CreateRoomButton
@onready var room_code_input: LineEdit = %RoomCodeInput
@onready var join_by_code_button: Button = %JoinByCodeButton
@onready var back_button: Button = %BackButton

var player_count_option: OptionButton = null
var target_score_option: OptionButton = null
var direction_option: OptionButton = null
var bots_toggle: CheckBox = null
var spectators_toggle: CheckBox = null

func _ready() -> void:
	_build_room_settings_controls()

	create_room_button.disabled = true
	join_by_code_button.disabled = true

	create_room_button.pressed.connect(_on_create_room_pressed)
	join_by_code_button.pressed.connect(_on_join_by_code_pressed)
	back_button.pressed.connect(_on_back_pressed)
	retry_button.pressed.connect(_on_retry_pressed)
	room_code_input.text_submitted.connect(_on_room_code_submitted)

	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.disconnected_from_server.connect(_on_disconnected_from_server)
	NetworkManager.room_created.connect(_on_room_created)
	NetworkManager.room_joined.connect(_on_room_joined)

	_ensure_connection()

func _ensure_connection() -> void:
	retry_button.visible = false

	var peer := multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_on_connected_to_server()
		return

	if peer == null or peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		status_label.text = "Connecting... waking the server can take a minute."
		NetworkManager.connect_to_server(_get_player_name())
		return

	# Still connecting: wait for the connected/failed signal.
	status_label.text = "Connecting... waking the server can take a minute."

func _get_player_name() -> String:
	if NetworkManager.local_player_name != "":
		return NetworkManager.local_player_name
	var config := ConfigFile.new()
	if config.load("user://profile.cfg") == OK:
		var saved := str(config.get_value("player", "name", ""))
		if saved != "":
			return saved
	return "Player"

func _on_retry_pressed() -> void:
	_ensure_connection()

func _on_create_room_pressed() -> void:
	NetworkManager.create_room(_get_room_settings())

func _on_room_code_submitted(_text: String) -> void:
	_on_join_by_code_pressed()

func _on_join_by_code_pressed() -> void:
	var room_code := room_code_input.text.strip_edges().to_upper()
	if room_code == "":
		return
	NetworkManager.join_room(room_code)

func _on_room_created(_room_code: String) -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Lobby.tscn")

func _on_room_joined(_room_code: String) -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Lobby.tscn")

func _on_back_pressed() -> void:
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

func _on_connected_to_server() -> void:
	status_label.text = "Connected"
	retry_button.visible = false
	create_room_button.disabled = false
	join_by_code_button.disabled = false

func _on_connection_failed() -> void:
	status_label.text = "Could not reach the server."
	retry_button.visible = true
	create_room_button.disabled = true
	join_by_code_button.disabled = true

func _on_disconnected_from_server() -> void:
	status_label.text = "Disconnected from server."
	retry_button.visible = true
	create_room_button.disabled = true
	join_by_code_button.disabled = true

func _add_setting_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_grid.add_child(label)

func _build_room_settings_controls() -> void:
	_add_setting_label("Players")
	player_count_option = OptionButton.new()
	player_count_option.add_item("4 Players", 4)
	player_count_option.add_item("6 Players", 6)
	player_count_option.add_item("8 Players", 8)
	player_count_option.selected = 0
	player_count_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_grid.add_child(player_count_option)

	_add_setting_label("Target score")
	target_score_option = OptionButton.new()
	target_score_option.add_item("12", 12)
	target_score_option.add_item("15", 15)
	target_score_option.add_item("21", 21)
	target_score_option.selected = 1
	target_score_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_grid.add_child(target_score_option)

	_add_setting_label("Direction")
	direction_option = OptionButton.new()
	direction_option.add_item("Counter-clockwise", 0)
	direction_option.add_item("Clockwise", 1)
	direction_option.selected = 0
	direction_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_grid.add_child(direction_option)

	bots_toggle = CheckBox.new()
	bots_toggle.text = "Fill empty seats with bots"
	bots_toggle.button_pressed = true
	settings_box.add_child(bots_toggle)

	spectators_toggle = CheckBox.new()
	spectators_toggle.text = "Allow spectators"
	spectators_toggle.button_pressed = true
	settings_box.add_child(spectators_toggle)

func _get_room_settings() -> Dictionary:
	return {
		"player_count": player_count_option.get_selected_id(),
		"target_score": target_score_option.get_selected_id(),
		"play_direction": "clockwise" if direction_option.get_selected_id() == 1 else "counter_clockwise",
		"private_room": true,
		"bots_enabled": bots_toggle.button_pressed,
		"spectators_enabled": spectators_toggle.button_pressed
	}
