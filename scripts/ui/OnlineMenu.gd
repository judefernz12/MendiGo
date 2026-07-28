extends Control

# Three short screens rather than one long one. Everything used to be stacked
# on a single card - room settings, a code box and every button - which meant
# scrolling past the half you did not want, and on a phone the half you did
# want was often below the fold. Now the first screen only asks what you came
# to do, and the setup for each answer gets a page to itself.

@onready var title_label: Label = %Title
@onready var status_label: Label = %StatusLabel
@onready var retry_button: Button = %RetryButton
@onready var back_button: Button = %BackButton

@onready var chooser_page: VBoxContainer = %ChooserPage
@onready var go_create_button: Button = %GoCreateButton
@onready var go_join_button: Button = %GoJoinButton
@onready var go_watch_button: Button = %GoWatchButton

@onready var create_page: VBoxContainer = %CreatePage
@onready var settings_grid: GridContainer = %SettingsGrid
@onready var settings_box: VBoxContainer = %SettingsBox
@onready var create_room_button: Button = %CreateRoomButton

@onready var join_page: VBoxContainer = %JoinPage
@onready var join_hint: Label = %JoinHint
@onready var room_code_input: LineEdit = %RoomCodeInput
@onready var join_by_code_button: Button = %JoinByCodeButton

const PAGE_CHOOSER := "chooser"
const PAGE_CREATE := "create"
const PAGE_JOIN := "join"

var player_count_option: OptionButton = null
var target_score_option: OptionButton = null
var direction_option: OptionButton = null
var bots_toggle: CheckBox = null
var spectators_toggle: CheckBox = null

# Watching is its own way in from the first screen now. Kept as a member under
# the old name because it is still "the button that leads to watching".
var watch_button: Button = null

var page: String = PAGE_CHOOSER
var join_as_spectator: bool = false

func _ready() -> void:
	_build_room_settings_controls()
	watch_button = go_watch_button

	go_create_button.pressed.connect(func(): _show_page(PAGE_CREATE))
	go_join_button.pressed.connect(func(): _open_join_page(false))
	go_watch_button.pressed.connect(func(): _open_join_page(true))

	create_room_button.pressed.connect(_on_create_room_pressed)
	join_by_code_button.pressed.connect(_on_join_by_code_pressed)
	back_button.pressed.connect(_on_back_pressed)
	retry_button.pressed.connect(_on_retry_pressed)
	room_code_input.text_submitted.connect(_on_room_code_submitted)
	room_code_input.text_changed.connect(_on_room_code_changed)
	WebKeyboard.attach(room_code_input, true)

	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.disconnected_from_server.connect(_on_disconnected_from_server)
	NetworkManager.room_created.connect(_on_room_created)
	NetworkManager.room_joined.connect(_on_room_joined)
	NetworkManager.room_error.connect(_on_room_error)

	_show_page(PAGE_CHOOSER)
	_set_room_actions_enabled(false)
	_ensure_connection()

# --- pages -----------------------------------------------------------------

func _show_page(next_page: String) -> void:
	page = next_page
	chooser_page.visible = next_page == PAGE_CHOOSER
	create_page.visible = next_page == PAGE_CREATE
	join_page.visible = next_page == PAGE_JOIN

	match next_page:
		PAGE_CREATE:
			title_label.text = "New Room"
		PAGE_JOIN:
			title_label.text = "Watch a Game" if join_as_spectator else "Join Room"
		_:
			title_label.text = "Play Online"

	# One Back button that means "up one level", so the chooser is never more
	# than a tap away and Home is never more than two.
	back_button.text = "Back" if next_page == PAGE_CHOOSER else "Back to Menu"
	_apply_enabled_state()

func _open_join_page(as_spectator: bool) -> void:
	join_as_spectator = as_spectator
	if as_spectator:
		join_hint.text = "Enter the code of the room you want to watch. You can watch a game that has already started."
		join_by_code_button.text = "Watch"
	else:
		join_hint.text = "Enter the 5-letter code from whoever made the room."
		join_by_code_button.text = "Join"
	room_code_input.text = ""
	WebKeyboard.sync(room_code_input)
	_show_page(PAGE_JOIN)
	# Not grab_focus(): on a phone browser that opens the engine's own hidden
	# input and hands it the keyboard, and the overlay never gets it back.
	WebKeyboard.focus(room_code_input)

func _on_back_pressed() -> void:
	if page != PAGE_CHOOSER:
		_show_page(PAGE_CHOOSER)
		return
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

# --- connection ------------------------------------------------------------

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

func _on_connected_to_server() -> void:
	status_label.text = "Connected"
	retry_button.visible = false
	_set_room_actions_enabled(true)

func _on_connection_failed() -> void:
	status_label.text = "Could not reach the server."
	retry_button.visible = true
	_set_room_actions_enabled(false)

func _on_disconnected_from_server() -> void:
	status_label.text = "Disconnected from server."
	retry_button.visible = true
	_set_room_actions_enabled(false)

var _connected: bool = false

func _set_room_actions_enabled(enabled: bool) -> void:
	_connected = enabled
	_apply_enabled_state()

func _apply_enabled_state() -> void:
	go_create_button.disabled = not _connected
	go_join_button.disabled = not _connected
	go_watch_button.disabled = not _connected
	create_room_button.disabled = not _connected
	# Nothing to join until a code has been typed, so the button says so
	# instead of answering a tap with silence.
	join_by_code_button.disabled = not _connected or room_code_input.text.strip_edges() == ""

func _on_room_code_changed(_text: String) -> void:
	_apply_enabled_state()

# --- actions ---------------------------------------------------------------

func _on_create_room_pressed() -> void:
	NetworkManager.create_room(_get_room_settings())

func _on_room_code_submitted(_text: String) -> void:
	_on_join_by_code_pressed()

func _on_join_by_code_pressed() -> void:
	var room_code := room_code_input.text.strip_edges().to_upper()
	if room_code == "":
		status_label.text = "Enter the room code you want to watch." if join_as_spectator else "Enter the room code you want to join."
		return
	NetworkManager.join_room(room_code, join_as_spectator)

func _on_watch_pressed() -> void:
	# Kept so "watch this code" is still one call from outside this screen.
	join_as_spectator = true
	_on_join_by_code_pressed()

func _on_room_created(_room_code: String) -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Lobby.tscn")

func _on_room_joined(_room_code: String) -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Lobby.tscn")

func _on_room_error(message: String) -> void:
	# The server refused the join. Saying so beats a button that looks dead.
	status_label.text = message
	status_label.add_theme_color_override("font_color", Color(0.95, 0.42, 0.40))
	await get_tree().create_timer(6.0).timeout
	if is_instance_valid(status_label):
		status_label.remove_theme_color_override("font_color")
		status_label.text = "Connected" if _connected else "Disconnected from server."

# --- room settings ---------------------------------------------------------

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
