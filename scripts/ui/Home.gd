extends Control

const HOW_TO_PLAY_TEXT := """Mendicot is a team trick-taking card game.

Teams: alternating seats form two teams (4, 6 or 8 players).
Goal: capture 10s. The team that captures more 10s wins the game.
Capture all four 10s for a "Court" (5 points). A normal win is 2 points.
First team to reach the target score (default 15) wins the match.

How a game plays:
1. Everyone picks a face-down card. Highest card deals first.
2. The player after the dealer receives the first cards and chooses
   Closed Trump (hide one card as secret trump) or Open Trump
   (first off-suit card played sets the trump).
3. You must follow the lead suit if you can. If you cannot, you may
   play any card - or reveal the hidden trump when playing closed.
4. Highest trump wins the trick; otherwise highest card of the lead suit.
5. The trick winner leads the next trick."""

const SETTINGS_PANEL_SCENE := "res://scenes/ui/SettingsPanel.tscn"

@onready var name_input: LineEdit = %NameInput
@onready var play_online_button: Button = %PlayOnlineButton
@onready var how_to_play_button: Button = %HowToPlayButton
@onready var settings_button: Button = %SettingsButton
@onready var exit_button: Button = %ExitButton

var how_to_play_dialog: AcceptDialog = null
var settings_panel: Control = null

func _ready() -> void:
	play_online_button.pressed.connect(_on_play_online_pressed)
	how_to_play_button.pressed.connect(_on_how_to_play_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	name_input.text = _load_player_name()
	WebKeyboard.attach(name_input)
	_build_settings_panel()

	if OS.has_feature("web"):
		exit_button.visible = false

func _build_settings_panel() -> void:
	settings_panel = load(SETTINGS_PANEL_SCENE).instantiate()
	add_child(settings_panel)
	# The name can be changed in either place, so whichever was used last is
	# what the other one shows.
	settings_panel.closed.connect(func():
		name_input.text = _load_player_name()
		WebKeyboard.sync(name_input))

func _on_settings_pressed() -> void:
	settings_panel.open()

func _on_play_online_pressed() -> void:
	var player_name := name_input.text.strip_edges()
	if player_name == "":
		player_name = "Player"

	_save_player_name(player_name)
	NetworkManager.connect_to_server(player_name)
	get_tree().change_scene_to_file("res://scenes/ui/OnlineMenu.tscn")

func _on_how_to_play_pressed() -> void:
	if how_to_play_dialog == null:
		how_to_play_dialog = AcceptDialog.new()
		how_to_play_dialog.title = "How To Play"
		how_to_play_dialog.dialog_text = HOW_TO_PLAY_TEXT
		add_child(how_to_play_dialog)
	how_to_play_dialog.popup_centered()

func _on_exit_pressed() -> void:
	get_tree().quit()

func _save_player_name(player_name: String) -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", player_name)
	config.save("user://profile.cfg")

func _load_player_name() -> String:
	var config := ConfigFile.new()
	var err := config.load("user://profile.cfg")
	if err != OK:
		return ""
	return str(config.get_value("player", "name", ""))
