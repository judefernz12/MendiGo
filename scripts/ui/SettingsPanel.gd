extends Control

# A settings overlay rather than a screen of its own, so it can be opened from
# anywhere without losing what is underneath it.

@onready var name_input: LineEdit = %SettingsNameInput
@onready var fullscreen_check: CheckBox = %FullscreenCheck
@onready var fullscreen_row: VBoxContainer = %FullscreenRow
@onready var auto_sort_check: CheckBox = %AutoSortCheck
@onready var version_label: Label = %VersionLabel
@onready var close_button: Button = %CloseButton

signal closed

func _ready() -> void:
	visible = false
	close_button.pressed.connect(close)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	auto_sort_check.toggled.connect(_on_auto_sort_toggled)
	WebKeyboard.attach(name_input)

	version_label.text = "MendiGo %s" % str(ProjectSettings.get_setting("application/config/version", "1.0"))

	# The switch is hidden rather than greyed out where it cannot work: on a
	# native phone build the game is already fullscreen, and iPhone Safari has
	# no element fullscreen to ask for.
	fullscreen_row.visible = GameSettings.supports_fullscreen()

func open() -> void:
	name_input.text = _load_player_name()
	WebKeyboard.sync(name_input)
	fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	auto_sort_check.set_pressed_no_signal(GameSettings.auto_sort_hand)
	fullscreen_row.visible = GameSettings.supports_fullscreen()
	visible = true
	# This panel is drawn over the screen that opened it, but that screen's own
	# text boxes are HTML elements on top of the canvas and carry on showing
	# through - which put two name boxes on screen at once. Claim the page
	# while this is up.
	WebKeyboard.push_exclusive(self)
	close_button.grab_focus()

func close() -> void:
	_save_player_name(name_input.text.strip_edges())
	WebKeyboard.pop_exclusive(self)
	visible = false
	emit_signal("closed")

func _on_fullscreen_toggled(on: bool) -> void:
	GameSettings.set_fullscreen(on)

func _on_auto_sort_toggled(on: bool) -> void:
	GameSettings.set_auto_sort_hand(on)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("back") or (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()

# --- the player name lives with the rest of the profile ---------------------

func _save_player_name(player_name: String) -> void:
	if player_name == "":
		return
	var config := ConfigFile.new()
	config.load("user://profile.cfg")
	config.set_value("player", "name", player_name)
	config.save("user://profile.cfg")
	NetworkManager.local_player_name = player_name

func _load_player_name() -> String:
	if NetworkManager.local_player_name != "":
		return NetworkManager.local_player_name
	var config := ConfigFile.new()
	if config.load("user://profile.cfg") != OK:
		return ""
	return str(config.get_value("player", "name", ""))
