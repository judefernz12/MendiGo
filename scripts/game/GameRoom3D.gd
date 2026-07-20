extends Node3D

const CARD_SCENE := preload("res://scenes/game/Card3D.tscn")
const CardDatabase = preload("res://scripts/game/CardDatabase.gd")

# View names in table order (offset from the local player).
# The server uses the same ordering when it builds per-player snapshots.
const ALL_VIEWS := ["my", "right", "top", "left", "seat4", "seat5", "seat6", "seat7"]

# Seat/trick positions are computed on elliptical rings around the table so
# any player count (4/6/8) lays out cleanly. The 4-player values match the
# original hand-placed markers exactly.
const SEAT_RING_CENTER := Vector3(0, 1, -0.3)
const SEAT_RING_RX := 3.2
const SEAT_RING_RZ := 2.1
const TRICK_RING_CENTER := Vector3(0, 1, 0)
const TRICK_RING_RX := 1.2
const TRICK_RING_RZ := 0.8

@onready var cards_node: Node3D = $Cards
@onready var play_button: Button = $CanvasLayer/HUD/PlayButton
@onready var deck_point: Marker3D = $DeckPoint

@onready var seat0_anchor: Marker3D = $SeatAnchors/Seat0_MyHand
@onready var seat1_anchor: Marker3D = $SeatAnchors/Seat1_Right
@onready var seat2_anchor: Marker3D = $SeatAnchors/Seat2_Top
@onready var seat3_anchor: Marker3D = $SeatAnchors/Seat3_Left

@onready var slot0_bottom: Marker3D = $TrickSlots/Slot0_Bottom
@onready var slot1_right: Marker3D = $TrickSlots/Slot1_Right
@onready var slot2_top: Marker3D = $TrickSlots/Slot2_Top
@onready var slot3_left: Marker3D = $TrickSlots/Slot3_Left

@onready var pile_team_a: Marker3D = $TeamPiles/PileTeamA
@onready var pile_team_b: Marker3D = $TeamPiles/PileTeamB

@onready var open_trump_button: Button = $CanvasLayer/HUD/OpenTrumpButton

@onready var trump_label: Label = $CanvasLayer/HUD/TrumpLabel
@onready var trump_reveal_card: TextureRect = $CanvasLayer/HUD/TrumpRevealCard

@onready var confirm_hidden_trump_button: Button = $CanvasLayer/HUD/ConfirmHiddenTrumpButton

@onready var hidden_trump_slot: Marker3D = $HiddenTrumpSlot
@onready var turn_timer_label: Label = $CanvasLayer/HUD/TurnTimerLabel

@onready var my_timer_anchor: Marker3D = $TurnTimerAnchors/MyTimerAnchor
@onready var right_timer_anchor: Marker3D = $TurnTimerAnchors/RightTimerAnchor
@onready var top_timer_anchor: Marker3D = $TurnTimerAnchors/TopTimerAnchor
@onready var left_timer_anchor: Marker3D = $TurnTimerAnchors/LeftTimerAnchor

@onready var turn_timer_widget: Control = $CanvasLayer/HUD/TurnTimerWidget
@onready var turn_timer_ring: TextureProgressBar = $CanvasLayer/HUD/TurnTimerWidget/TurnTimerRing
@onready var turn_timer_text: Label = $CanvasLayer/HUD/TurnTimerWidget/TurnTimerText
@onready var phase_message_panel: PanelContainer = $CanvasLayer/HUD/PhaseMessagePanel
@onready var phase_message_label: Label = $CanvasLayer/HUD/PhaseMessagePanel/PhaseMessageLabel
@onready var trump_suit_icon: TextureRect = $CanvasLayer/HUD/TrumpSuitIcon
@onready var arrange_button: Button = $CanvasLayer/HUD/ArrangeButton

var scoreboard_label: Label = null
var result_label: Label = null
var leave_button: Button = null
var seat_nameplates: Dictionary = {}
var extra_hand_arrays: Dictionary = {}

var dealer_draw_card_nodes_by_index: Dictionary = {}
var dealer_draw_claimed_animated: Dictionary = {}

var local_seat_id: String = ""
var local_view_to_abs := {
	"my": "",
	"right": "",
	"top": "",
	"left": ""
}
var abs_to_local_view := {}

var dealer_draw_visual_cards: Array = []

var current_match_phase: String = ""
var dealer_draw_cards: Array = []
var dealer_draw_selected_index: int = -1
var trump_holder_abs_seat_id: String = ""

var seat_to_player := {
	"my": {"id":"", "name":"", "is_bot":false, "is_local":false, "seat_id":""},
	"right": {"id":"", "name":"", "is_bot":true, "is_local":false, "seat_id":""},
	"top": {"id":"", "name":"", "is_bot":true, "is_local":false, "seat_id":""},
	"left": {"id":"", "name":"", "is_bot":true, "is_local":false, "seat_id":""}
}

var is_match_host: bool = false
var is_server_authoritative_match: bool = false
var has_received_initial_snapshot: bool = false

var hidden_trump_card_node: Node3D = null
var hidden_trump_holder_seat: String = ""

var first_batch_dealt: bool = false
var my_hand_cards: Array = []
var right_hand_cards: Array = []
var top_hand_cards: Array = []
var left_hand_cards: Array = []
var selected_card: Node3D = null

var trick_cards: Array = [] # each item: { "seat": String, "card": Node3D }
var team_a_trick_count: int = 0
var team_b_trick_count: int = 0

var current_player_count: int = 4
var current_deal_pattern: Array = []
var current_deck: Array = []

var sample_ten_index_a: int = 0
var sample_ten_index_b: int = 0

var current_lead_suit: String = ""
var trump_reveal_in_progress: bool = false
var trump_icon_tween: Tween = null

var sample_tens: Array = [
	{"suit": "clubs", "rank": "10"},
	{"suit": "diamonds", "rank": "10"},
	{"suit": "hearts", "rank": "10"},
	{"suit": "spades", "rank": "10"}
]


var local_player_id: String = ""

var seat_order: Array = ["my", "right", "top", "left"]
var current_turn_index: int = 0
var current_leader_index: int = 0
var trick_in_progress: bool = false
var trick_is_resolving: bool = false
var trick_slots_filled: Dictionary = {}

var trump_mode: String = "open" # later: "hidden"
var trump_active: bool = false
var trump_suit: String = ""

var hidden_trump_card_data: Dictionary = {}
var hidden_trump_revealed: bool = false

var awaiting_hidden_trump_play: bool = false

var input_phase_active: bool = false

var dealer_seat: String = "left"

var selecting_hidden_trump: bool = false

# Keep in sync with TURN_DEADLINE_S in Server.gd.
var turn_time_limit: float = 20.0
var current_turn_time_left: float = 0.0
var turn_timer_active: bool = false
var turn_timer_token: int = 0

var timer_pulse_t: float = 0.0
var turn_timer_fade_tween: Tween = null
var my_hand_is_arranged: bool = false

var game_state: Dictionary = {}
var card_nodes_by_id: Dictionary = {}

var state_restore_generation: int = 0
var scene_rebuild_in_progress: bool = false

var seat_is_bot := {
	"my": false,
	"right": true,
	"top": true,
	"left": true
}

var seat_timeout_autoplay := {
	"my": false,
	"right": false,
	"top": false,
	"left": false
}

# Parallel stepped pile tuning for top-view camera:
# X stays same
# Y rises slightly to avoid z-fighting
# Z moves forward so previous trick stacks remain visible
const PILE_STACK_Y_STEP: float = 0.01
const PILE_STACK_Z_STEP: float = 0.2

const TEN_SPACING_X: float = 0.22
const TEN_OFFSET_Y: float = 0.015
const TEN_OFFSET_Z: float = 0.0

func _ready() -> void:
	var match_setup := _load_match_setup()
	var players: Array = match_setup.get("players", [])

	if not players.is_empty():
		_init_seat_players(players)
		_apply_bot_flags_from_seats()

	is_match_host = bool(match_setup.get("is_host", false))
	is_server_authoritative_match = bool(match_setup.get("server_authoritative", false))
	dealer_seat = abs_to_local_view.get(str(match_setup.get("dealer_seat_id", "seat_0")), "my")

	_apply_match_phase_setup(match_setup)
	NetworkManager.game_state_snapshot_received.connect(_on_game_state_snapshot_received)
	NetworkManager.game_action_received.connect(_on_game_action_received)
	NetworkManager.dealer_draw_updated.connect(_on_network_dealer_draw_updated)
	NetworkManager.trump_mode_choice_requested.connect(_on_network_trump_mode_choice_requested)
	NetworkManager.disconnected_from_server.connect(_on_server_connection_lost)

	_ensure_status_ui()
	_ensure_nameplates()

	play_button.disabled = true
	confirm_hidden_trump_button.pressed.connect(_on_confirm_hidden_trump_button_pressed)
	confirm_hidden_trump_button.visible = false
	confirm_hidden_trump_button.disabled = true

	arrange_button.pressed.connect(_on_arrange_button_pressed)
	open_trump_button.pressed.connect(_on_open_trump_button_pressed)

	trump_active = false
	trump_suit = ""
	trump_mode = str(match_setup.get("trump_mode", "hidden"))
	if trump_mode == "":
		trump_mode = "hidden"
	hidden_trump_card_data = {}
	hidden_trump_revealed = false
	awaiting_hidden_trump_play = false
	selecting_hidden_trump = false
	first_batch_dealt = false
	hidden_trump_card_node = null
	has_received_initial_snapshot = false
	dealer_draw_selected_index = -1

	trump_suit_icon.visible = false
	trump_suit_icon.modulate.a = 1.0
	trump_suit_icon.scale = Vector2.ONE

	open_trump_button.visible = false
	open_trump_button.disabled = true
	trump_reveal_card.visible = false

	turn_timer_widget.visible = false
	turn_timer_widget.modulate.a = 0.0
	turn_timer_label.visible = false

	input_phase_active = false
	_refresh_action_buttons()
	_refresh_hidden_trump_selection_ui()
	_refresh_trump_label()
	_refresh_scoreboard()
	_refresh_phase_message()

	if is_server_authoritative_match:
		game_state = _create_initial_game_state()
		input_phase_active = false
		turn_timer_active = false
		trick_in_progress = false
		trick_is_resolving = false
		_refresh_action_buttons()
		_refresh_hidden_trump_selection_ui()
		_refresh_trump_label()
	elif current_match_phase == "dealer_draw":
		_build_dealer_draw_cards()
	elif current_match_phase == "trump_mode_choice":
		_build_dealer_draw_cards()
		_show_trump_mode_choice_if_needed()
	elif is_match_host:
		current_deck = CardDatabase.create_deck_for_player_count(current_player_count)
		current_deck = CardDatabase.shuffle_deck(current_deck)
		current_deal_pattern = _get_deal_pattern(current_player_count)

		_refresh_distributor_and_trump_holder()
		game_state = _create_initial_game_state()

		if trump_mode == "hidden":
			await _deal_4_player_pattern_hidden_mode()
			_broadcast_full_game_state()
		else:
			await _deal_4_player_pattern()
			await _reveal_my_hand_after_real_deal()
			_sync_runtime_to_game_state()
			input_phase_active = true
			await _start_new_trick(current_leader_index)
			_broadcast_full_game_state()
	else:
		game_state = _create_initial_game_state()
		input_phase_active = false
		turn_timer_active = false
		trick_in_progress = false
		trick_is_resolving = false
		_refresh_action_buttons()
		_refresh_hidden_trump_selection_ui()
		_refresh_trump_label()

	turn_timer_label.visible = false
	_refresh_turn_timer_label()
	_refresh_scoreboard()
	_refresh_phase_message()

	if is_server_authoritative_match:
		if not NetworkManager.latest_game_state_snapshot.is_empty():
			_on_game_state_snapshot_received(NetworkManager.latest_game_state_snapshot)
		else:
			NetworkManager.request_game_state()

func _ensure_status_ui() -> void:
	var hud: Control = $CanvasLayer/HUD

	var score_panel := PanelContainer.new()
	score_panel.name = "ScorePanel"
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.04, 0.09, 0.06, 0.82)
	panel_style.set_corner_radius_all(10)
	panel_style.content_margin_left = 14
	panel_style.content_margin_right = 14
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	score_panel.add_theme_stylebox_override("panel", panel_style)
	score_panel.position = Vector2(14, 12)
	score_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(score_panel)

	scoreboard_label = Label.new()
	scoreboard_label.name = "ScoreboardLabel"
	scoreboard_label.add_theme_font_size_override("font_size", 15)
	scoreboard_label.add_theme_color_override("font_color", Color(0.9, 0.96, 0.91))
	scoreboard_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_panel.add_child(scoreboard_label)

	result_label = Label.new()
	result_label.name = "ResultLabel"
	result_label.anchor_left = 0.5
	result_label.anchor_right = 0.5
	result_label.offset_left = -240.0
	result_label.offset_right = 240.0
	result_label.offset_top = 14.0
	result_label.offset_bottom = 42.0
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 18)
	result_label.add_theme_color_override("font_color", Color(1, 0.9, 0.45, 1))
	result_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	result_label.add_theme_constant_override("outline_size", 4)
	result_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(result_label)

	leave_button = Button.new()
	leave_button.name = "LeaveButton"
	leave_button.text = "Leave"
	leave_button.anchor_left = 1.0
	leave_button.anchor_right = 1.0
	leave_button.offset_left = -96.0
	leave_button.offset_top = 12.0
	leave_button.offset_right = -14.0
	leave_button.offset_bottom = 50.0
	leave_button.pressed.connect(_on_leave_button_pressed)
	hud.add_child(leave_button)

func _on_leave_button_pressed() -> void:
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

func _on_server_connection_lost() -> void:
	input_phase_active = false
	_stop_turn_timer()
	_refresh_action_buttons()
	phase_message_panel.visible = true
	phase_message_label.text = "Connection lost. Press Leave to return to the menu."

func _ensure_nameplates() -> void:
	var hud: Control = $CanvasLayer/HUD

	for view_name in seat_order:
		if view_name == "my":
			continue
		if seat_nameplates.has(view_name):
			continue
		var plate := Label.new()
		plate.name = "Nameplate_%s" % view_name
		plate.size = Vector2(170, 24)
		plate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plate.add_theme_font_size_override("font_size", 15)
		plate.add_theme_color_override("font_color", Color(0.92, 0.96, 0.93))
		plate.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		plate.add_theme_constant_override("outline_size", 5)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.z_index = 5
		hud.add_child(plate)
		seat_nameplates[view_name] = plate

	for view_name in seat_nameplates.keys():
		var plate: Label = seat_nameplates[view_name]
		if not seat_order.has(view_name):
			plate.queue_free()
			seat_nameplates.erase(view_name)

func _get_nameplate_world_position(view_name: String) -> Vector3:
	var theta := _seat_angle_rad(view_name)
	return SEAT_RING_CENTER + Vector3(cos(theta) * SEAT_RING_RX * 0.68, 0.2, sin(theta) * SEAT_RING_RZ * 0.68)

func _update_nameplates() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return

	var current_turn_view := ""
	if input_phase_active:
		current_turn_view = _get_current_turn_seat()

	for view_name in seat_nameplates.keys():
		var plate: Label = seat_nameplates[view_name]
		var p: Dictionary = seat_to_player.get(view_name, {})
		var display := str(p.get("name", ""))
		if display == "":
			display = str(view_name).capitalize()
		if dealer_seat == view_name:
			display += "  (Dealer)"
		if not bool(p.get("is_connected", true)) and not bool(p.get("is_bot", false)):
			display += "  [offline]"
		plate.text = display

		var screen := camera.unproject_position(_get_nameplate_world_position(view_name))
		plate.position = screen - plate.size * 0.5

		if view_name == current_turn_view:
			plate.add_theme_color_override("font_color", Color(1.0, 0.84, 0.4))
		else:
			plate.add_theme_color_override("font_color", Color(0.92, 0.96, 0.93))


func _valid_player_count(count: int) -> int:
	if count == 4 or count == 6 or count == 8:
		return count
	return 4

# --- Seat ring geometry (works for 4, 6 and 8 players) ---

func _view_offset_index(view_name: String) -> int:
	var idx := seat_order.find(view_name)
	if idx == -1:
		return 0
	return idx

func _seat_angle_rad(view_name: String) -> float:
	var n := maxi(1, seat_order.size())
	return deg_to_rad(90.0 - float(_view_offset_index(view_name)) * (360.0 / float(n)))

func _get_seat_anchor_position(view_name: String) -> Vector3:
	var theta := _seat_angle_rad(view_name)
	return SEAT_RING_CENTER + Vector3(cos(theta) * SEAT_RING_RX, 0.0, sin(theta) * SEAT_RING_RZ)

func _get_trick_slot_position(view_name: String) -> Vector3:
	var theta := _seat_angle_rad(view_name)
	return TRICK_RING_CENTER + Vector3(cos(theta) * TRICK_RING_RX, 0.0, sin(theta) * TRICK_RING_RZ)

func _get_play_rotation_for_view(view_name: String) -> Vector3:
	return Vector3(90.0, 0.0, -20.0 * cos(_seat_angle_rad(view_name)))

func _hand_array_for_view(view_name: String) -> Array:
	match view_name:
		"my":
			return my_hand_cards
		"right":
			return right_hand_cards
		"top":
			return top_hand_cards
		"left":
			return left_hand_cards
	if not extra_hand_arrays.has(view_name):
		extra_hand_arrays[view_name] = []
	return extra_hand_arrays[view_name]

func _init_seat_players(players: Array) -> void:
	current_player_count = _valid_player_count(players.size())
	seat_order = ALL_VIEWS.slice(0, current_player_count)

	seat_to_player = {}
	seat_is_bot = {}
	seat_timeout_autoplay = {}
	for view_name in seat_order:
		seat_to_player[view_name] = {"id": "", "name": "", "is_bot": true, "is_local": false, "seat_id": ""}
		seat_is_bot[view_name] = true
		seat_timeout_autoplay[view_name] = false

	local_player_id = ""
	local_seat_id = ""

	var players_by_seat := {}
	for p_raw in players:
		var p: Dictionary = p_raw
		var seat_id: String = str(p.get("seat_id", ""))
		players_by_seat[seat_id] = p

		if bool(p.get("is_local", false)):
			local_player_id = str(p.get("id", ""))
			local_seat_id = seat_id

	if local_seat_id == "":
		local_seat_id = "seat_0"

	_build_local_view_mapping()

	for view_name in seat_order:
		var abs_seat_id: String = str(local_view_to_abs.get(view_name, ""))
		if players_by_seat.has(abs_seat_id):
			seat_to_player[view_name] = players_by_seat[abs_seat_id]
		else:
			seat_to_player[view_name] = {
				"id":"",
				"name":str(view_name).capitalize(),
				"is_bot":true,
				"is_local":false,
				"seat_id":abs_seat_id
			}

	_ensure_nameplates()

func _get_deal_pattern(player_count: int) -> Array:
	match player_count:
		4:
			return [5, 4, 4]
		6:
			return [4, 4]
		8:
			return [3, 3]
		_:
			return []

func _get_cards_per_player(player_count: int) -> int:
	match player_count:
		4:
			return 13
		6:
			return 8
		8:
			return 6
		_:
			return 0

func _create_card() -> Node3D:
	var card := CARD_SCENE.instantiate()
	cards_node.add_child(card)
	card.position = deck_point.position
	card.rotation_degrees = Vector3(0, 0, 0)
	card.scale = Vector3(1.0, 1.0, 1.0)
	card.set_face_up(false)
	return card


func _get_my_hand_transform(index: int, count: int) -> Dictionary:
	var center: float = (count - 1) / 2.0

	# Maximum width your full hand is allowed to occupy
	var max_span: float = 4.0

	# Default spacing for smaller hands
	var spacing: float = 0.5
	if count > 1:
		spacing = min(0.8, max_span / float(count - 1))

	var offset: float = (index - center) * spacing

	# Slight curved fan
	var z_curve: float = abs(index - center) * 0.10
	var fan_angle: float = (index - center) * 5.5

	# Tiny anti-glitch stagger
	var y_stagger: float = index * 0.001

	var pos: Vector3 = seat0_anchor.position + Vector3(offset, y_stagger, z_curve)
	var rot: Vector3 = Vector3(90, 0, fan_angle)

	return {
		"position": pos,
		"rotation": rot
	}

func _get_right_hand_transform(index: int, count: int) -> Dictionary:
	var center: float = (count - 1) / 2.0
	var max_span: float = 2.4
	var spacing: float = 0.6

	if count > 1:
		spacing = min(0.6, max_span / float(count - 1))

	var offset: float = (index - center) * spacing
	var fan_angle: float = (index - center) * 4.0

	# tiny anti-glitch stagger
	var x_stagger: float = index * 0.002
	var y_stagger: float = index * 0.001

	var pos: Vector3 = seat1_anchor.position + Vector3(x_stagger, y_stagger, offset)
	var rot: Vector3 = Vector3(0, 90, fan_angle)

	return {
		"position": pos,
		"rotation": rot
	}

func _get_top_hand_transform(index: int, count: int) -> Dictionary:
	var center: float = (count - 1) / 2.0
	var max_span: float = 3.4
	var spacing: float = 0.6

	if count > 1:
		spacing = min(0.6, max_span / float(count - 1))

	var offset: float = (index - center) * spacing
	var fan_angle: float = (center - index) * 5.0

	# tiny anti-glitch stagger
	var y_stagger: float = index * 0.001
	var z_stagger: float = index * 0.002

	var pos: Vector3 = seat2_anchor.position + Vector3(offset, y_stagger, z_stagger)
	var rot: Vector3 = Vector3(0, 180, fan_angle)

	return {
		"position": pos,
		"rotation": rot
	}

func _get_left_hand_transform(index: int, count: int) -> Dictionary:
	var center: float = (count - 1) / 2.0
	var max_span: float = 2.4
	var spacing: float = 0.6

	if count > 1:
		spacing = min(0.6, max_span / float(count - 1))

	var offset: float = (index - center) * spacing
	var fan_angle: float = (center - index) * 4.0

	# tiny anti-glitch stagger
	var x_stagger: float = -index * 0.002
	var y_stagger: float = index * 0.001

	var pos: Vector3 = seat3_anchor.position + Vector3(x_stagger, y_stagger, -offset)
	var rot: Vector3 = Vector3(0, -90, fan_angle)

	return {
		"position": pos,
		"rotation": rot
	}

func _get_opponent_hand_transform(view_name: String, index: int, count: int) -> Dictionary:
	var theta := _seat_angle_rad(view_name)
	var seat_pos := _get_seat_anchor_position(view_name)
	var center_f: float = (count - 1) / 2.0

	var max_span := 2.4 if current_player_count == 4 else 1.7
	var spacing := 0.6 if current_player_count == 4 else 0.45
	if count > 1:
		spacing = minf(spacing, max_span / float(count - 1))

	var offset := (float(index) - center_f) * spacing
	var tangent := Vector3(-sin(theta), 0.0, cos(theta))
	var pos := seat_pos + tangent * offset + Vector3(0.0, float(index) * 0.001, 0.0)
	var y_rot := 90.0 - rad_to_deg(theta)
	var fan := (center_f - float(index)) * 4.0

	return {
		"position": pos,
		"rotation": Vector3(0.0, y_rot, fan)
	}

func _layout_hand(hand_array: Array, seat_name: String) -> void:
	var count: int = hand_array.size()

	for i: int in range(count):
		var card = hand_array[i]
		var t: Dictionary

		if seat_name == "my":
			t = _get_my_hand_transform(i, count)
		elif seat_order.has(seat_name):
			t = _get_opponent_hand_transform(seat_name, i, count)
		else:
			return

		card.home_position = t["position"]
		card.home_rotation = t["rotation"]

		# Do not move the newly-dealing card here.
		if card.is_dealing:
			continue

		# Do not move played cards.
		if card.played:
			continue

		# Selected card should keep its lifted position relative to its updated home.
		if card.selected:
			var tween_selected := create_tween()
			tween_selected.set_trans(Tween.TRANS_SINE)
			tween_selected.set_ease(Tween.EASE_OUT)
			tween_selected.parallel().tween_property(
				card,
				"position",
				card.home_position + Vector3(0, 0.18, 0),
				0.2
			)
			tween_selected.parallel().tween_property(
				card,
				"rotation_degrees",
				card.home_rotation,
				0.2
			)
		else:
			var tween := create_tween()
			tween.set_trans(Tween.TRANS_SINE)
			tween.set_ease(Tween.EASE_OUT)
			tween.parallel().tween_property(card, "position", card.home_position, 0.2)
			tween.parallel().tween_property(card, "rotation_degrees", card.home_rotation, 0.2)

func _deal_my_hand() -> void:
	var count: int = 5

	for i: int in range(count):
		var card = _create_card()

		var card_data: Dictionary = current_deck.pop_back()
		card.set_card_data(card_data)

		var t := _get_my_hand_transform(i, count)
		var home_pos: Vector3 = t["position"]
		var home_rot: Vector3 = t["rotation"]

		card.home_position = home_pos
		card.home_rotation = home_rot

		card.play_position = slot0_bottom.position
		card.play_rotation = Vector3(90, 0, 0)

		card.card_clicked.connect(_on_card_clicked)
		my_hand_cards.append(card)

		_animate_deal(card, home_pos, home_rot, i * 0.12)

	_reveal_hand_after_delay(count)

@warning_ignore("unused_parameter")
func _deal_opponent_hand(anchor: Marker3D, count: int, base_rotation: Vector3, hand_array: Array) -> void:
	for i: int in range(count):
		var card = _create_card()

		var card_data: Dictionary = current_deck.pop_back()
		card.set_card_data(card_data)

		card.clickable = false
		card.set_face_up(false)

		var t: Dictionary

		if anchor == seat1_anchor:
			t = _get_right_hand_transform(i, count)
		elif anchor == seat2_anchor:
			t = _get_top_hand_transform(i, count)
		else:
			t = _get_left_hand_transform(i, count)

		var home_pos: Vector3 = t["position"]
		var home_rot: Vector3 = t["rotation"]

		card.home_position = home_pos
		card.home_rotation = home_rot

		_animate_deal(card, home_pos, home_rot, i * 0.12)
		hand_array.append(card)

func _animate_deal(card: Node3D, target_pos: Vector3, target_rot: Vector3, delay: float) -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)

	tween.tween_interval(delay)
	tween.parallel().tween_property(card, "position", target_pos, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.35)


func _reveal_hand_after_delay(count: int) -> void:
	var total_delay: float = count * 0.12 + 0.5
	await get_tree().create_timer(total_delay).timeout

	for i: int in range(my_hand_cards.size()):
		var card = my_hand_cards[i]
		card.flip_card()
		await get_tree().create_timer(0.08).timeout

func _on_card_clicked(card: Node3D) -> void:
	if trick_is_resolving:
		return

	if trump_reveal_in_progress:
		return

	if selecting_hidden_trump:
		if hidden_trump_holder_seat != "my":
			return

		if selected_card == card:
			card.set_selected(false)
			selected_card = null
			_refresh_hidden_trump_selection_ui()
			return

		if selected_card != null:
			selected_card.set_selected(false)

		selected_card = card
		selected_card.set_selected(true)
		_refresh_hidden_trump_selection_ui()
		return

	if _get_current_turn_seat() != "my":
		return

	# Normal follow-suit legality
	if not _is_card_legal_for_hand(card, my_hand_cards):
		print("Selected illegal card. Must follow suit: ", current_lead_suit)
		return

	# After hidden trump reveal, enforce trump play if trump is available
	if not _is_card_legal_after_hidden_trump_reveal(card, my_hand_cards):
		print("Selected illegal card after hidden trump reveal. Must play trump suit: ", trump_suit)
		return

	if selected_card == card:
		card.set_selected(false)
		selected_card = null
		_refresh_action_buttons()
		return

	if selected_card != null:
		selected_card.set_selected(false)

	selected_card = card
	selected_card.set_selected(true)
	_refresh_action_buttons()

func _on_play_button_pressed() -> void:
	if selected_card == null:
		return

	await _submit_player_action({
		"type": "play_card",
		"seat": "my",
		"card_id": selected_card.card_id
	})

@warning_ignore("unused_parameter")
func _play_from_opponent_hand(hand_array: Array, slot_pos: Vector3, slot_rot: Vector3) -> void:
	if hand_array.is_empty():
		return

	var seat_name: String = ""
	var my_generation: int = state_restore_generation
	if hand_array == right_hand_cards:
		seat_name = "right"
	elif hand_array == top_hand_cards:
		seat_name = "top"
	elif hand_array == left_hand_cards:
		seat_name = "left"

	if seat_name == "":
		return

	# Hidden trump reveal branch for bots/opponents
	if _should_opponent_reveal_hidden_trump(hand_array, seat_name):
		trump_reveal_in_progress = true
		_refresh_action_buttons()

		_reveal_hidden_trump_for_opponent(seat_name)
		_show_trump_opened_message()

		await get_tree().create_timer(6.0).timeout

		if my_generation != state_restore_generation:
			return
		if hidden_trump_card_node != null and not is_instance_valid(hidden_trump_card_node):
			return

		await _return_hidden_trump_to_holder_hand()

		if my_generation != state_restore_generation:
			return

		trump_reveal_in_progress = false
		_refresh_trump_suit_icon()
		_animate_trump_suit_icon_in()
		_clear_phase_message_if_not_selecting()
		_refresh_action_buttons()

	var card_id: String = _get_legal_card_id_for_seat(seat_name)
	if card_id == "":
		return

	await _submit_player_action({
		"type": "play_card",
		"seat": seat_name,
		"card_id": card_id
	})


func _get_pile_position(team: String) -> Vector3:
	if team == "A":
		var stack_index: int = team_a_trick_count
		return pile_team_a.position + Vector3(
			0,
			PILE_STACK_Y_STEP * stack_index,
			PILE_STACK_Z_STEP * stack_index
		)
	else:
		var stack_index: int = team_b_trick_count
		return pile_team_b.position + Vector3(
			0,
			PILE_STACK_Y_STEP * stack_index,
			PILE_STACK_Z_STEP * stack_index
		)


func _capture_trick(team: String) -> void:
	if trick_cards.is_empty():
		return

	var pile_pos: Vector3 = _get_pile_position(team)
	var pile_rot := Vector3(90, 0, 0)

	var ten_cards_data: Array = _get_ten_cards_from_trick()
	print("Tens in trick: ", ten_cards_data)

	for entry in trick_cards:
		var card: Node3D = entry["card"]
		card.clickable = false

		var tween := create_tween()
		tween.set_trans(Tween.TRANS_SINE)
		tween.set_ease(Tween.EASE_IN_OUT)
		tween.parallel().tween_property(card, "position", pile_pos, 0.4)
		tween.parallel().tween_property(card, "rotation_degrees", pile_rot, 0.4)

	await get_tree().create_timer(0.45).timeout

	_create_stack_visual(pile_pos, ten_cards_data)

	for entry in trick_cards:
		var card: Node3D = entry["card"]
		card.queue_free()

	trick_cards.clear()
	_clear_trick_after_capture()
	#_set_turn_state_in_game_state()

	if team == "A":
		team_a_trick_count += 1
	else:
		team_b_trick_count += 1
		
	_set_turn_state_in_game_state()
	_sync_runtime_to_game_state()

func _capture_trick_with_tens(team: String, ten_count: int) -> void:
	if trick_cards.is_empty():
		return

	var pile_pos: Vector3 = _get_pile_position(team)
	var pile_rot := Vector3(90, 0, 0)

	for entry in trick_cards:
		var card: Node3D = entry["card"]
		card.clickable = false

		var tween := create_tween()
		tween.set_trans(Tween.TRANS_SINE)
		tween.set_ease(Tween.EASE_IN_OUT)
		tween.parallel().tween_property(card, "position", pile_pos, 0.4)
		tween.parallel().tween_property(card, "rotation_degrees", pile_rot, 0.4)

	await get_tree().create_timer(0.45).timeout

	var ten_cards_data: Array = _get_sample_ten_cards(ten_count, team)
	_create_stack_visual(pile_pos, ten_cards_data)

	for entry in trick_cards:
		var card: Node3D = entry["card"]
		card.queue_free()

	trick_cards.clear()
	_clear_trick_after_capture()
	#_set_turn_state_in_game_state()
	if team == "A":
		team_a_trick_count += 1
	else:
		team_b_trick_count += 1
		
	_set_turn_state_in_game_state()
	_sync_runtime_to_game_state()

func _create_stack_visual(stack_pos: Vector3, ten_cards_data: Array) -> void:
	var bundle = _create_card()
	bundle.clickable = false
	bundle.played = true
	bundle.set_face_up(false)
	bundle.position = stack_pos
	bundle.rotation_degrees = Vector3(90, 0, 0)

	if ten_cards_data.is_empty():
		return

	var ten_count: int = ten_cards_data.size()
	var start_x: float = -((ten_count - 1) * TEN_SPACING_X) / 2.0

	for i in range(ten_count):
		var ten_card_data: Dictionary = ten_cards_data[i]

		var ten_card = _create_card()
		ten_card.clickable = false
		ten_card.played = true
		ten_card.set_card_data(ten_card_data)
		ten_card.set_face_up(true)

		var offset_x: float = start_x + i * TEN_SPACING_X

		# Make cards further to the right sit slightly higher and a tiny bit forward,
		# so the right card consistently appears above the left card.
		var offset_y: float = TEN_OFFSET_Y + i * 0.002
		var offset_z: float = TEN_OFFSET_Z + i * 0.001

		ten_card.position = stack_pos
		ten_card.rotation_degrees = Vector3(90, 0, 0)

		var tween := create_tween()
		tween.set_trans(Tween.TRANS_SINE)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_interval(i * 0.08)
		tween.parallel().tween_property(
			ten_card,
			"position",
			stack_pos + Vector3(offset_x, offset_y, offset_z),
			0.2
		)

func _add_card_to_my_hand(card_data: Dictionary, delay: float) -> void:
	var card = _create_card()
	card.set_card_data(card_data)
	card.card_clicked.connect(_on_card_clicked)
	card.play_position = slot0_bottom.position
	card.play_rotation = Vector3(90, 0, 0)

	card.is_dealing = true
	card.position = deck_point.position
	card.rotation_degrees = Vector3(0, 0, 0)

	my_hand_cards.append(card)

	# First update the whole hand layout so every card gets correct home_position.
	_layout_hand(my_hand_cards, "my")

	# Now animate only the new card from the deck to its correct target.
	var target_pos: Vector3 = card.home_position
	var target_rot: Vector3 = card.home_rotation

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_interval(delay)
	tween.parallel().tween_property(card, "position", target_pos, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.35)
	tween.finished.connect(func():
		card.is_dealing = false
	)

func _add_card_to_opponent_hand(hand_array: Array, seat_name: String, card_data: Dictionary, delay: float) -> void:
	var card = _create_card()
	card.set_card_data(card_data)
	card.clickable = false
	card.set_face_up(false)

	card.is_dealing = true
	card.position = deck_point.position
	card.rotation_degrees = Vector3(0, 0, 0)

	hand_array.append(card)

	# First update the whole hand layout so all cards have correct home_position.
	_layout_hand(hand_array, seat_name)

	var target_pos: Vector3 = card.home_position
	var target_rot: Vector3 = card.home_rotation

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_interval(delay)
	tween.parallel().tween_property(card, "position", target_pos, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.35)
	tween.finished.connect(func():
		card.is_dealing = false
	)

func _deal_4_player_pattern() -> void:
	var deal_order := _get_deal_seat_order_from_dealer()

	for batch_count in current_deal_pattern:
		for seat_name in deal_order:
			for _i in range(batch_count):
				if current_deck.is_empty():
					return

				var card_data: Dictionary = current_deck.pop_back()

				match seat_name:
					"my":
						await _deal_one_card_to_my_hand(card_data)
					"right":
						await _deal_one_card_to_opponent_hand(right_hand_cards, "right", card_data)
					"top":
						await _deal_one_card_to_opponent_hand(top_hand_cards, "top", card_data)
					"left":
						await _deal_one_card_to_opponent_hand(left_hand_cards, "left", card_data)

				await get_tree().create_timer(0.03).timeout

func _reveal_my_hand_after_real_deal() -> void:
	var my_generation: int = state_restore_generation
	for card in my_hand_cards:
		if my_generation != state_restore_generation:
			return
		if not is_instance_valid(card):
			continue
		card.flip_card()
		await get_tree().create_timer(0.08).timeout
		if my_generation != state_restore_generation:
			return

func _deal_one_card_to_my_hand(card_data: Dictionary) -> void:
	var card = _create_card()
	card.set_card_data(card_data)
	card_nodes_by_id[card.card_id] = card
	card.card_clicked.connect(_on_card_clicked)
	card.play_position = slot0_bottom.position
	card.play_rotation = Vector3(90, 0, 0)

	card.position = deck_point.position
	card.rotation_degrees = Vector3(0, 0, 0)

	my_hand_cards.append(card)

	# Recompute the whole hand layout now that one more card exists
	var count: int = my_hand_cards.size()
	for i in range(count):
		var existing_card = my_hand_cards[i]
		var t := _get_my_hand_transform(i, count)
		existing_card.home_position = t["position"]
		existing_card.home_rotation = t["rotation"]

	# Only animate the newly dealt card from deck point
	var target_pos: Vector3 = card.home_position
	var target_rot: Vector3 = card.home_rotation

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", target_pos, 0.22)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.22)

	await tween.finished

	# After the card lands, gently re-layout the whole hand
	_layout_hand(my_hand_cards, "my")

func _deal_one_card_to_opponent_hand(hand_array: Array, seat_name: String, card_data: Dictionary) -> void:
	var card = _create_card()
	card.set_card_data(card_data)
	card_nodes_by_id[card.card_id] = card
	card.clickable = false
	card.set_face_up(false)

	card.position = deck_point.position
	card.rotation_degrees = Vector3(0, 0, 0)

	hand_array.append(card)

	# Recompute the whole hand layout now that one more card exists
	var count: int = hand_array.size()
	for i in range(count):
		var existing_card = hand_array[i]
		var t: Dictionary

		match seat_name:
			"right":
				t = _get_right_hand_transform(i, count)
			"top":
				t = _get_top_hand_transform(i, count)
			"left":
				t = _get_left_hand_transform(i, count)
			_:
				return

		existing_card.home_position = t["position"]
		existing_card.home_rotation = t["rotation"]

	# Only animate the newly dealt card from deck point
	var target_pos: Vector3 = card.home_position
	var target_rot: Vector3 = card.home_rotation

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", target_pos, 0.22)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.22)

	await tween.finished

	# After the card lands, gently re-layout the whole hand
	_layout_hand(hand_array, seat_name)


func _get_sample_ten_cards(count: int, team: String) -> Array:
	var result: Array = []

	for i in range(count):
		if team == "A":
			var data: Dictionary = sample_tens[(sample_ten_index_a + i) % sample_tens.size()]
			result.append(data)
		else:
			var data: Dictionary = sample_tens[(sample_ten_index_b + i) % sample_tens.size()]
			result.append(data)

	if team == "A":
		sample_ten_index_a = (sample_ten_index_a + count) % sample_tens.size()
	else:
		sample_ten_index_b = (sample_ten_index_b + count) % sample_tens.size()

	return result

func _get_ten_cards_from_trick() -> Array:
	var tens: Array = []
	var trick_state: Array = _get_state_trick_cards()

	for entry in trick_state:
		if str(entry["rank"]) == "10":
			tens.append({
				"suit": str(entry["suit"]),
				"rank": str(entry["rank"])
			})

	return tens


func _start_new_trick(leader_index: int) -> void:
	game_state["current_leader_index"] = leader_index
	game_state["current_turn_index"] = leader_index
	game_state["trick_in_progress"] = true
	game_state["trick_is_resolving"] = false
	game_state["current_lead_suit"] = ""
	_clear_trick_state()

	current_leader_index = leader_index
	current_turn_index = leader_index
	trick_in_progress = true
	trick_is_resolving = false
	trick_cards.clear()
	trick_slots_filled.clear()
	current_lead_suit = ""
	selected_card = null
	awaiting_hidden_trump_play = false

	_clear_phase_message_if_not_selecting()
	_sync_game_state_to_runtime()
	_refresh_action_buttons()
	_start_turn_timer_for_current_seat()

	print("New trick started. Leader: ", seat_order[current_turn_index])

	await _try_autoplay_current_seat()

func _get_current_turn_seat() -> String:
	var idx: int = int(game_state.get("current_turn_index", current_turn_index))
	if idx < 0 or idx >= seat_order.size():
		return ""
	return seat_order[idx]


func _advance_turn() -> void:
	var next_index: int = (current_turn_index + 1) % seat_order.size()

	game_state["current_turn_index"] = next_index
	current_turn_index = next_index

	_sync_game_state_to_runtime()
	print("Next turn: ", seat_order[current_turn_index])

func _try_autoplay_current_seat() -> void:
	if not is_match_host:
		return

	if trick_is_resolving:
		return

	var seat: String = _get_current_turn_seat()

	if not _seat_should_autoplay(seat):
		if seat == "my":
			print("Your turn")
			_refresh_action_buttons()
		return

	match seat:
		"right":
			await get_tree().create_timer(0.4).timeout
			await _play_from_opponent_hand(right_hand_cards, slot1_right.position, Vector3(90, 0, -20))
		"top":
			await get_tree().create_timer(0.4).timeout
			await _play_from_opponent_hand(top_hand_cards, slot2_top.position, Vector3(90, 0, 0))
		"left":
			await get_tree().create_timer(0.4).timeout
			await _play_from_opponent_hand(left_hand_cards, slot3_left.position, Vector3(90, 0, 20))
		"my":
			await get_tree().create_timer(0.4).timeout
			await _autoplay_my_seat()

func _after_seat_played() -> void:
	if trick_cards.size() >= 4:
		await _resolve_trick()
		return

	_advance_turn()
	_refresh_action_buttons()
	_start_turn_timer_for_current_seat()
	await _try_autoplay_current_seat()

func _resolve_trick() -> void:
	if not is_match_host:
		return

	if trick_is_resolving:
		return

	trick_is_resolving = true
	var my_generation: int = state_restore_generation
	print("Resolving trick...")

	await get_tree().create_timer(0.4).timeout
	if my_generation != state_restore_generation:
		return

	var winner_index: int = _get_trick_winner_index()
	var winner_seat: String = seat_order[winner_index]
	game_state["current_leader_index"] = winner_index
	_set_turn_state_in_game_state()
	_sync_game_state_to_runtime()
	print("Winner: ", winner_seat)

	if winner_seat == "my" or winner_seat == "top":
		_capture_trick("A")
	else:
		_capture_trick("B")

	await get_tree().create_timer(0.6).timeout
	if my_generation != state_restore_generation:
		return

	current_leader_index = winner_index
	await _start_new_trick(current_leader_index)

	if is_match_host:
		_broadcast_full_game_state()


func _get_rank_value(rank: String) -> int:
	match rank:
		"2":
			return 2
		"3":
			return 3
		"4":
			return 4
		"5":
			return 5
		"6":
			return 6
		"7":
			return 7
		"8":
			return 8
		"9":
			return 9
		"10":
			return 10
		"jack":
			return 11
		"queen":
			return 12
		"king":
			return 13
		"ace":
			return 14
		_:
			return 0

func _get_trick_winner_index() -> int:
	var trick_state: Array = _get_state_trick_cards()
	if trick_state.is_empty():
		return current_leader_index

	var first_entry: Dictionary = trick_state[0]
	var lead_suit: String = str(first_entry["suit"])

	var trump_entries: Array = []

	for entry in trick_state:
		var was_trump: bool = entry.get("was_trump_at_play_time", false)
		var suit: String = str(entry["suit"])

		if was_trump and trump_active and suit.to_lower() == trump_suit.to_lower():
			trump_entries.append(entry)

	if not trump_entries.is_empty():
		var winning_entry: Dictionary = trump_entries[0]
		var winning_value: int = _get_rank_value(str(winning_entry["rank"]))

		for entry in trump_entries:
			var value: int = _get_rank_value(str(entry["rank"]))
			if value > winning_value:
				winning_entry = entry
				winning_value = value

		var winner_seat: String = str(winning_entry["seat"])
		return seat_order.find(winner_seat)

	var winning_entry: Dictionary = first_entry
	var winning_value: int = _get_rank_value(str(winning_entry["rank"]))

	for entry in trick_state:
		var suit: String = str(entry["suit"])
		if suit.to_lower() != lead_suit.to_lower():
			continue

		var value: int = _get_rank_value(str(entry["rank"]))
		if value > winning_value:
			winning_entry = entry
			winning_value = value

	var winner_seat: String = str(winning_entry["seat"])
	return seat_order.find(winner_seat)

func _my_hand_has_suit(suit: String) -> bool:
	for card in my_hand_cards:
		if card.suit == suit:
			return true
	return false

func _is_my_selected_card_legal(card: Node3D) -> bool:
	return _is_card_legal_for_hand(card, my_hand_cards)


func _hand_has_suit(hand_array: Array, suit: String) -> bool:
	for card in hand_array:
		if card.suit.to_lower() == suit.to_lower():
			return true
	return false


func _is_card_legal_for_hand(card: Node3D, hand_array: Array) -> bool:
	# No lead suit yet: any card can be played
	if current_lead_suit == "":
		return true

	# If the hand contains the lead suit, the card must match it
	if _hand_has_suit(hand_array, current_lead_suit):
		return card.suit.to_lower() == current_lead_suit.to_lower()

	# Otherwise the player is void and may play anything
	return true

func _get_first_legal_card_index(hand_array: Array) -> int:
	for i in range(hand_array.size()):
		var card = hand_array[i]
		if _is_card_legal_for_hand(card, hand_array):
			return i
	return -1

func _refresh_action_buttons() -> void:
	if current_match_phase == "trump_mode_choice":
		play_button.visible = false
		play_button.disabled = true
		return

	if selecting_hidden_trump:
		play_button.visible = false
		play_button.disabled = true
		open_trump_button.visible = false
		open_trump_button.disabled = true
		return

	if not input_phase_active:
		play_button.visible = false
		play_button.disabled = true
		open_trump_button.visible = false
		open_trump_button.disabled = true
		return

	var is_my_turn: bool = (_get_current_turn_seat() == "my") and not trick_is_resolving and not trump_reveal_in_progress

	play_button.visible = is_my_turn
	play_button.disabled = (not is_my_turn) or (selected_card == null)

	var can_open_hidden: bool = _can_my_hand_open_hidden_trump() and not trump_reveal_in_progress
	open_trump_button.visible = can_open_hidden
	open_trump_button.disabled = not can_open_hidden

func _can_play_selected_card_without_opening(card: Node3D, hand_array: Array) -> bool:
	return _is_card_legal_for_hand(card, hand_array)


func _maybe_activate_open_trump(card: Node3D, was_void_in_lead_suit: bool) -> bool:
	# Only open mode uses automatic trump activation.
	if trump_mode != "open":
		return false

	# If trump already active, nothing to do.
	if trump_active:
		return false

	# No lead suit yet -> first card of trick cannot auto-open trump.
	if current_lead_suit == "":
		return false

	# Must be void in lead suit.
	if not was_void_in_lead_suit:
		return false

	# If the played card is the lead suit itself, this is not opening trump.
	if card.suit.to_lower() == current_lead_suit.to_lower():
		return false

	# Player is void and played an off-suit card:
	# that suit automatically becomes trump.
	trump_active = true
	trump_suit = card.suit
	game_state["trump_active"] = true
	game_state["trump_suit"] = trump_suit
	_sync_game_state_to_runtime()
	_refresh_trump_label()
	_refresh_trump_suit_icon()
	_refresh_scoreboard()
	phase_message_panel.visible = true
	phase_message_label.text = "Trump Opened: " + trump_suit.capitalize()
	print("Open trump activated automatically: ", trump_suit)
	return true


func _can_my_hand_open_hidden_trump() -> bool:
	if not input_phase_active:
		return false

	if trump_mode != "hidden":
		return false

	if trump_active:
		return false

	if awaiting_hidden_trump_play:
		return false

	if trick_is_resolving:
		return false

	if not trick_in_progress:
		return false

	if _get_current_turn_seat() != "my":
		return false

	if current_lead_suit == "":
		return false

	# Can only open hidden trump if void in lead suit
	if _hand_has_suit(my_hand_cards, current_lead_suit):
		return false

	return true


func _hand_has_hidden_trump_suit(hand_array: Array) -> bool:
	if hidden_trump_card_data.is_empty():
		return false

	var hidden_suit: String = hidden_trump_card_data["suit"]
	return _hand_has_suit(hand_array, hidden_suit)


func _can_open_hidden_trump_with_selected_card(card: Node3D, hand_array: Array) -> bool:
	if hidden_trump_card_data.is_empty():
		return false

	var hidden_suit: String = hidden_trump_card_data["suit"]

	# If player has hidden trump suit, they must play that suit when opening.
	if _hand_has_suit(hand_array, hidden_suit):
		return card.suit.to_lower() == hidden_suit.to_lower()

	# If they have no trump suit, any card is allowed.
	return true

func _on_open_trump_button_pressed() -> void:
	if current_match_phase == "trump_mode_choice":
		NetworkManager.choose_trump_mode("open")
		return

	await _submit_player_action({
		"type": "open_trump",
		"seat": "my"
	})

func _refresh_trump_label() -> void:
	if trump_active:
		trump_label.text = "Trump: " + trump_suit.capitalize()
	else:
		trump_label.text = "Trump: None"

func _refresh_scoreboard() -> void:
	if scoreboard_label == null:
		return

	var scores: Dictionary = game_state.get("scores", {"A": 0, "B": 0})
	var captured_10s: Dictionary = game_state.get("captured_10s", {"A": 0, "B": 0})
	var target_score: int = int(game_state.get("target_score", 15))
	var dealer_text := _get_display_name_for_seat(dealer_seat)
	var turn_text := _get_display_name_for_seat(_get_current_turn_seat())
	var trump_text := trump_suit.capitalize() if (trump_active and trump_suit != "") else "None"

	scoreboard_label.text = "Team A %s  •  Team B %s   (to %d)\n10s  %s - %s      Tricks  %d - %d\nDealer: %s      Turn: %s\nTrump: %s" % [
		str(scores.get("A", 0)),
		str(scores.get("B", 0)),
		target_score,
		str(captured_10s.get("A", 0)),
		str(captured_10s.get("B", 0)),
		team_a_trick_count,
		team_b_trick_count,
		dealer_text,
		turn_text,
		trump_text
	]

	if result_label == null:
		return

	var result: Dictionary = game_state.get("last_game_result", {})
	if result.is_empty():
		result_label.text = ""
		return

	var result_type := "Court" if bool(result.get("court", false)) else "Normal"
	result_label.text = "Team %s wins %s (+%d)" % [
		str(result.get("winner", "")),
		result_type,
		int(result.get("points", 0))
	]

func _show_hidden_trump_reveal() -> void:
	if hidden_trump_card_node == null:
		return

	hidden_trump_card_node.set_face_up(true)

func _hide_hidden_trump_reveal() -> void:
	# Do nothing here for hidden trump physical card.
	pass

func _is_card_legal_after_hidden_trump_reveal(card: Node3D, hand_array: Array) -> bool:
	if not trump_active:
		return true

	if trump_mode != "hidden":
		return true

	if not awaiting_hidden_trump_play:
		return true

	# After hidden trump is revealed, if player has trump suit,
	# they must play a trump card.
	if _hand_has_suit(hand_array, trump_suit):
		return card.suit.to_lower() == trump_suit.to_lower()

	# If no trump suit in hand, any card is allowed.
	return true

func _get_first_card_index_of_suit(hand_array: Array, suit: String) -> int:
	for i in range(hand_array.size()):
		var card = hand_array[i]
		if card.suit.to_lower() == suit.to_lower():
			return i
	return -1

func _should_opponent_reveal_hidden_trump(hand_array: Array, seat_name: String) -> bool:
	if trump_mode != "hidden":
		return false

	if trump_active:
		return false

	if current_lead_suit == "":
		return false

	# Must be void in lead suit
	if _hand_has_suit(hand_array, current_lead_suit):
		return false

	if hidden_trump_card_data.is_empty():
		return false

	var hidden_suit: String = hidden_trump_card_data["suit"]

	# Good reason 1: this player is the hidden trump holder,
	# so revealing returns the hidden trump card to their hand.
	if seat_name == hidden_trump_holder_seat:
		return true

	# Good reason 2: player already has a trump-suit card in hand,
	# so revealing lets them use it.
	if _hand_has_suit(hand_array, hidden_suit):
		return true

	# Otherwise keep trump hidden and discard normally.
	return false


func _get_opponent_card_index_for_hidden_trump_play(hand_array: Array) -> int:
	if hidden_trump_card_data.is_empty():
		return -1

	var hidden_suit: String = hidden_trump_card_data["suit"]

	# If opponent has trump suit after reveal, must play trump
	var trump_index: int = _get_first_card_index_of_suit(hand_array, hidden_suit)
	if trump_index != -1:
		return trump_index

	# Otherwise they can play anything
	if hand_array.is_empty():
		return -1

	return 0

func _reveal_hidden_trump_for_opponent(seat_name: String) -> void:
	if hidden_trump_card_data.is_empty():
		return

	trump_active = true
	trump_suit = hidden_trump_card_data["suit"]
	hidden_trump_revealed = true
	awaiting_hidden_trump_play = false
	game_state["trump_active"] = true
	game_state["trump_suit"] = trump_suit
	game_state["hidden_trump_revealed"] = true
	game_state["awaiting_hidden_trump_play"] = false
	_mark_hidden_trump_revealed_in_state()
	_sync_game_state_to_runtime()
	_refresh_trump_label()

	print("Hidden trump revealed by ", seat_name, ": ", hidden_trump_card_data["suit"], " ", hidden_trump_card_data["rank"])

	_show_hidden_trump_reveal()

func _begin_hidden_trump_selection() -> void:
	selecting_hidden_trump = true
	input_phase_active = false
	selected_card = null
	_refresh_action_buttons()
	_refresh_hidden_trump_selection_ui()
	_refresh_phase_message()
	print("Hidden trump selection started. Holder: ", hidden_trump_holder_seat)

	if hidden_trump_holder_seat != "my":
		await get_tree().create_timer(1.0).timeout
		await _auto_select_hidden_trump_for_opponent()
		return

	# If I am the holder, pause here until I confirm the hidden trump choice.
	while selecting_hidden_trump:
		await get_tree().process_frame


#func _refresh_hidden_trump_selection_ui() -> void:
	#if selecting_hidden_trump and hidden_trump_holder_seat == "my":
		#confirm_hidden_trump_button.visible = true
		#confirm_hidden_trump_button.disabled = (selected_card == null)
	#else:
		#confirm_hidden_trump_button.visible = false
		#confirm_hidden_trump_button.disabled = true
func _refresh_hidden_trump_selection_ui() -> void:
	if not selecting_hidden_trump:
		confirm_hidden_trump_button.visible = false
		confirm_hidden_trump_button.disabled = true
		return

	var my_turn_to_choose: bool = (hidden_trump_holder_seat == "my")

	confirm_hidden_trump_button.text = "Hide This Card"
	confirm_hidden_trump_button.visible = my_turn_to_choose
	confirm_hidden_trump_button.disabled = (selected_card == null)

func _on_confirm_hidden_trump_button_pressed() -> void:
	if current_match_phase == "trump_mode_choice":
		NetworkManager.choose_trump_mode("hidden")
		return

	if selected_card == null:
		return

	await _submit_player_action({
		"type": "confirm_hidden_trump",
		"seat": "my",
		"card_id": selected_card.card_id
	})

func _auto_select_hidden_trump_for_opponent() -> void:
	var holder_hand: Array = []
	var my_generation: int = state_restore_generation
	match hidden_trump_holder_seat:
		"right":
			holder_hand = right_hand_cards
		"top":
			holder_hand = top_hand_cards
		"left":
			holder_hand = left_hand_cards
		"my":
			holder_hand = my_hand_cards

	if holder_hand.is_empty():
		print("Opponent hidden trump selection failed: holder hand empty")
		return

	var card = holder_hand[0]

	hidden_trump_card_data = {
		"card_id": card.card_id,
		"suit": card.suit,
		"rank": card.rank
	}
	hidden_trump_revealed = false
	hidden_trump_card_node = card

	_set_hidden_trump_in_state(card, hidden_trump_holder_seat)
	game_state["hidden_trump_revealed"] = false
	game_state["awaiting_hidden_trump_play"] = false

	print("Hidden trump chosen by ", hidden_trump_holder_seat, ": ", hidden_trump_card_data["suit"], " ", hidden_trump_card_data["rank"])
	var removed_card_state: Dictionary = _remove_card_from_state_hand(hidden_trump_holder_seat, card.card_id)
	if removed_card_state.is_empty():
		print("Failed to remove opponent hidden trump card from state hand")
		return
	holder_hand.erase(card)

	card.clickable = false
	card.set_face_up(false)

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", hidden_trump_slot.position, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", Vector3(90, 0, 0), 0.35)

	await tween.finished

	if my_generation != state_restore_generation:
		return
	if not is_instance_valid(card):
		return

	selecting_hidden_trump = false
	_refresh_phase_message()
	_refresh_hidden_trump_selection_ui()

	match hidden_trump_holder_seat:
		"right":
			_layout_hand(right_hand_cards, "right")
		"top":
			_layout_hand(top_hand_cards, "top")
		"left":
			_layout_hand(left_hand_cards, "left")
		"my":
			_layout_hand(my_hand_cards, "my")

func _deal_4_player_pattern_hidden_mode() -> void:
	var deal_order := _get_deal_seat_order_from_dealer()

	# First batch only
	var first_batch: int = current_deal_pattern[0]

	for seat_name in deal_order:
		for _i in range(first_batch):
			if current_deck.is_empty():
				return

			var card_data: Dictionary = current_deck.pop_back()

			match seat_name:
				"my":
					await _deal_one_card_to_my_hand(card_data)
				"right":
					await _deal_one_card_to_opponent_hand(right_hand_cards, "right", card_data)
				"top":
					await _deal_one_card_to_opponent_hand(top_hand_cards, "top", card_data)
				"left":
					await _deal_one_card_to_opponent_hand(left_hand_cards, "left", card_data)

			await get_tree().create_timer(0.03).timeout

	first_batch_dealt = true
	_sync_runtime_to_game_state()
	# Hidden trump holder must now choose 1 from first batch
	await _begin_hidden_trump_selection()

	# Deal remaining batches
	for batch_index in range(1, current_deal_pattern.size()):
		var batch_count: int = current_deal_pattern[batch_index]

		for seat_name in deal_order:
			for _i in range(batch_count):
				if current_deck.is_empty():
					return

				var card_data: Dictionary = current_deck.pop_back()

				match seat_name:
					"my":
						await _deal_one_card_to_my_hand(card_data)
					"right":
						await _deal_one_card_to_opponent_hand(right_hand_cards, "right", card_data)
					"top":
						await _deal_one_card_to_opponent_hand(top_hand_cards, "top", card_data)
					"left":
						await _deal_one_card_to_opponent_hand(left_hand_cards, "left", card_data)

				await get_tree().create_timer(0.03).timeout

	await _reveal_my_hand_after_real_deal()
	_sync_runtime_to_game_state()
	input_phase_active = true
	_start_new_trick(current_leader_index)

func _return_hidden_trump_to_holder_hand() -> void:
	_mark_hidden_trump_returned_in_state()
	game_state["awaiting_hidden_trump_play"] = awaiting_hidden_trump_play
	_sync_game_state_to_runtime()
	if hidden_trump_card_node == null:
		return

	var card = hidden_trump_card_node
	var my_generation: int = state_restore_generation
	var returned_card_state := {
		"card_id": card.card_id,
		"suit": card.suit,
		"rank": card.rank,
		"is_face_up": hidden_trump_holder_seat == "my"
	}
	var target_pos := Vector3.ZERO
	var target_rot := Vector3.ZERO

	match hidden_trump_holder_seat:
		"my":
			_append_card_to_state_hand("my", returned_card_state)
			my_hand_cards.append(card)
			card.clickable = true
			card.set_face_up(true)

			if my_hand_is_arranged:
				_arrange_my_hand()

			var t := _get_my_hand_transform(my_hand_cards.find(card), my_hand_cards.size())
			target_pos = t["position"]
			target_rot = t["rotation"]

		"right":
			_append_card_to_state_hand("right", returned_card_state)
			right_hand_cards.append(card)
			card.clickable = false
			card.set_face_up(false)

			var t := _get_right_hand_transform(right_hand_cards.size() - 1, right_hand_cards.size())
			target_pos = t["position"]
			target_rot = t["rotation"]

		"top":
			_append_card_to_state_hand("top", returned_card_state)
			top_hand_cards.append(card)
			card.clickable = false
			card.set_face_up(false)

			var t := _get_top_hand_transform(top_hand_cards.size() - 1, top_hand_cards.size())
			target_pos = t["position"]
			target_rot = t["rotation"]

		"left":
			_append_card_to_state_hand("left", returned_card_state)
			left_hand_cards.append(card)
			card.clickable = false
			card.set_face_up(false)

			var t := _get_left_hand_transform(left_hand_cards.size() - 1, left_hand_cards.size())
			target_pos = t["position"]
			target_rot = t["rotation"]

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", target_pos, 0.4)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, 0.4)

	await tween.finished
	
	if my_generation != state_restore_generation:
		return
	if not is_instance_valid(card):
		return

	match hidden_trump_holder_seat:
		"my":
			_layout_hand(my_hand_cards, "my")
			_sync_runtime_hand_order_to_state("my", my_hand_cards)
		"right":
			_layout_hand(right_hand_cards, "right")
			_sync_runtime_hand_order_to_state("right", right_hand_cards)
		"top":
			_layout_hand(top_hand_cards, "top")
			_sync_runtime_hand_order_to_state("top", top_hand_cards)
		"left":
			_layout_hand(left_hand_cards, "left")
			_sync_runtime_hand_order_to_state("left", left_hand_cards)

	if hidden_trump_holder_seat == "my" and awaiting_hidden_trump_play:
		var trump_cards: Array = []
		for c in my_hand_cards:
			if c.suit.to_lower() == trump_suit.to_lower():
				trump_cards.append(c)

		if trump_cards.size() == 1:
			selected_card = trump_cards[0]
			selected_card.set_selected(true)
			_refresh_action_buttons()

	hidden_trump_card_node = null
	if is_match_host:
		_broadcast_full_game_state()

func _get_next_clockwise_seat(from_seat: String) -> String:
	var idx := seat_order.find(from_seat)
	if idx == -1:
		return "my"
	return seat_order[(idx + 1) % seat_order.size()]


func _refresh_distributor_and_trump_holder() -> void:
	hidden_trump_holder_seat = _get_next_clockwise_seat(dealer_seat)
	current_leader_index = seat_order.find(hidden_trump_holder_seat)

	print("Dealer: ", dealer_seat)
	print("Hidden trump holder: ", hidden_trump_holder_seat)
	print("First leader: ", hidden_trump_holder_seat)

func _get_deal_seat_order_from_dealer() -> Array:
	var order: Array = []
	var dealer_index: int = seat_order.find(dealer_seat)

	if dealer_index == -1:
		return ["my", "right", "top", "left"]

	for i in range(1, seat_order.size() + 1):
		order.append(seat_order[(dealer_index + i) % seat_order.size()])

	return order

func _seat_should_autoplay(seat_name: String) -> bool:
	var p: Dictionary = seat_to_player.get(seat_name, {})

	if bool(p.get("is_bot", false)):
		return true

	# Timeout autoplay must override local-human check
	if seat_timeout_autoplay.get(seat_name, false):
		return true

	if str(p.get("id", "")) == local_player_id:
		return false

	return false

func _autoplay_my_seat() -> void:
	if my_hand_cards.is_empty():
		return

	var card_id: String = _get_legal_card_id_for_seat("my")
	if card_id == "":
		return

	print("Timeout autoplay: normal discard/play only, no hidden trump reveal")

	await _submit_player_action({
		"type": "play_card",
		"seat": "my",
		"card_id": card_id
	})

func _enable_my_timeout_autoplay() -> void:
	seat_timeout_autoplay["my"] = true

func _disable_my_timeout_autoplay() -> void:
	seat_timeout_autoplay["my"] = false
	
func _refresh_turn_timer_label() -> void:
	if not input_phase_active or not turn_timer_active:
		turn_timer_label.visible = false
		return

	var active_seat: String = _get_current_turn_seat()

	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		turn_timer_widget.visible = false
		return

	var screen_pos: Vector2 = camera.unproject_position(_get_timer_anchor_position(active_seat))

	turn_timer_widget.visible = true
	turn_timer_widget.position = screen_pos - turn_timer_widget.size * 0.5

	# Text shows whole seconds
	turn_timer_text.text = str(int(ceil(current_turn_time_left)))

	# Ring uses smooth continuous float value
	var progress_ratio: float = clamp(current_turn_time_left / turn_time_limit, 0.0, 1.0)
	turn_timer_ring.value = progress_ratio * 100.0

	var timer_color: Color = _get_timer_color(current_turn_time_left)
	turn_timer_text.modulate = timer_color
	turn_timer_ring.tint_progress = timer_color

func _stop_turn_timer() -> void:
	turn_timer_active = false
	current_turn_time_left = 0.0
	turn_timer_token += 1
	timer_pulse_t = 0.0
	turn_timer_widget.scale = Vector2.ONE
	turn_timer_label.visible = false
	_fade_out_turn_timer_widget()


func _start_turn_timer_for_current_seat() -> void:
	_stop_turn_timer()

	var seat: String = _get_current_turn_seat()

	# Only human seats need the 15-second timer.
	if _seat_should_autoplay(seat):
		return

	turn_timer_active = true
	current_turn_time_left = turn_time_limit
	turn_timer_token += 1
	var my_token: int = turn_timer_token

	_refresh_turn_timer_label()
	_fade_in_turn_timer_widget()
	_run_turn_timer_loop(seat, my_token)

func _run_turn_timer_loop(seat_name: String, token: int) -> void:
	while turn_timer_active:
		if token != turn_timer_token:
			return

		if _get_current_turn_seat() != seat_name:
			return

		if trick_is_resolving:
			return

		await get_tree().process_frame

		if token != turn_timer_token:
			return

		if not turn_timer_active:
			return

		if current_turn_time_left <= 0.0:
			print("Turn timer expired for seat: ", seat_name)
			turn_timer_active = false
			_refresh_turn_timer_label()

			seat_timeout_autoplay[seat_name] = true
			await _try_autoplay_current_seat()
			return


func _get_timer_anchor_position(seat_name: String) -> Vector3:
	if current_player_count == 4:
		match seat_name:
			"my":
				return my_timer_anchor.position
			"right":
				return right_timer_anchor.position
			"top":
				return top_timer_anchor.position
			"left":
				return left_timer_anchor.position

	if not seat_order.has(seat_name):
		return my_timer_anchor.position

	return _get_trick_slot_position(seat_name).lerp(_get_seat_anchor_position(seat_name), 0.55)


func _get_timer_color(seconds_left: float) -> Color:
	var green := Color(0.2, 1.0, 0.2, 1.0)
	var red := Color(1.0, 0.2, 0.2, 1.0)

	if seconds_left > 5.0:
		return green

	var t: float = clamp((5.0 - seconds_left) / 5.0, 0.0, 1.0)
	return green.lerp(red, t)


func _update_timer_pulse(delta: float) -> void:
	if not turn_timer_active:
		turn_timer_widget.scale = Vector2.ONE
		return

	if current_turn_time_left > 5.0:
		turn_timer_widget.scale = Vector2.ONE
		return

	timer_pulse_t += delta * 6.0
	var pulse: float = 1.0 + 0.06 * abs(sin(timer_pulse_t))
	turn_timer_widget.scale = Vector2(pulse, pulse)


func _process(delta: float) -> void:
	if turn_timer_active:
		current_turn_time_left = max(0.0, current_turn_time_left - delta)
		_refresh_turn_timer_label()

	_update_timer_pulse(delta)
	_update_nameplates()
	
func _fade_in_turn_timer_widget() -> void:
	if turn_timer_fade_tween != null:
		turn_timer_fade_tween.kill()

	turn_timer_widget.visible = true
	turn_timer_widget.modulate.a = 0.0

	turn_timer_fade_tween = create_tween()
	turn_timer_fade_tween.set_trans(Tween.TRANS_SINE)
	turn_timer_fade_tween.set_ease(Tween.EASE_OUT)
	turn_timer_fade_tween.tween_property(turn_timer_widget, "modulate:a", 1.0, 0.18)


func _fade_out_turn_timer_widget() -> void:
	if turn_timer_fade_tween != null:
		turn_timer_fade_tween.kill()

	turn_timer_fade_tween = create_tween()
	turn_timer_fade_tween.set_trans(Tween.TRANS_SINE)
	turn_timer_fade_tween.set_ease(Tween.EASE_OUT)
	turn_timer_fade_tween.tween_property(turn_timer_widget, "modulate:a", 0.0, 0.15)
	turn_timer_fade_tween.tween_callback(func():
		turn_timer_widget.visible = false
)

func _get_display_name_for_seat(seat_name: String) -> String:
	if seat_name == "my":
		return "You"
	if seat_name == "":
		return "-"
	var p: Dictionary = seat_to_player.get(seat_name, {})
	return str(p.get("name", str(seat_name).capitalize()))

func _refresh_phase_message() -> void:
	if current_match_phase == "trump_mode_choice":
		_show_trump_mode_choice_if_needed()
		return

	if selecting_hidden_trump:
		phase_message_panel.visible = true

		if hidden_trump_holder_seat == "my":
			phase_message_label.text = "Choose 1 card from your first hand to hide as trump."
		else:
			phase_message_label.text = "Wait for %s to select trump." % _get_display_name_for_seat(hidden_trump_holder_seat)

		return

	if current_match_phase == "game_result" or current_match_phase == "match_result":
		var result: Dictionary = game_state.get("last_game_result", {})
		phase_message_panel.visible = true
		if result.is_empty():
			phase_message_label.text = "Game complete."
		elif bool(result.get("draw", false)):
			phase_message_label.text = "Draw! No points awarded. Next deal starting..."
		else:
			var result_type := "Court" if bool(result.get("court", false)) else "Normal"
			if current_match_phase == "match_result":
				phase_message_label.text = "Team %s wins the match! (%s win, +%d)" % [
					str(result.get("winner", "")),
					result_type,
					int(result.get("points", 0))
				]
			else:
				phase_message_label.text = "Team %s wins %s for %d points. Next deal starting..." % [
					str(result.get("winner", "")),
					result_type,
					int(result.get("points", 0))
				]
		return

	phase_message_panel.visible = false
	phase_message_label.text = ""



func _show_trump_opened_message() -> void:
	phase_message_panel.visible = true
	phase_message_label.text = "Trump Opened: " + trump_suit.capitalize()

func _clear_phase_message_if_not_selecting() -> void:
	if selecting_hidden_trump:
		_refresh_phase_message()
		return

	phase_message_panel.visible = false
	phase_message_label.text = ""

func _get_trump_icon_path(suit_name: String) -> String:
	match suit_name.to_lower():
		"spades":
			return "res://assets/ui/trump_icons/spades.png"
		"hearts":
			return "res://assets/ui/trump_icons/hearts.png"
		"diamonds":
			return "res://assets/ui/trump_icons/diamonds.png"
		"clubs":
			return "res://assets/ui/trump_icons/clubs.png"
		_:
			return ""
			
func _refresh_trump_suit_icon() -> void:
	if not trump_active or trump_suit == "":
		if trump_icon_tween != null:
			trump_icon_tween.kill()

		trump_suit_icon.visible = false
		trump_suit_icon.modulate.a = 1.0
		trump_suit_icon.scale = Vector2.ONE
		return

	var path := _get_trump_icon_path(trump_suit)
	if path == "" or not ResourceLoader.exists(path):
		trump_suit_icon.visible = false
		return

	trump_suit_icon.texture = load(path)
	trump_suit_icon.visible = true
	
	
func _animate_trump_suit_icon_in() -> void:
	if trump_icon_tween != null:
		trump_icon_tween.kill()

	trump_suit_icon.visible = true
	trump_suit_icon.modulate.a = 0.0
	trump_suit_icon.scale = Vector2(0.75, 0.75)

	trump_icon_tween = create_tween()
	trump_icon_tween.set_trans(Tween.TRANS_SINE)
	trump_icon_tween.set_ease(Tween.EASE_OUT)

	trump_icon_tween.parallel().tween_property(trump_suit_icon, "modulate:a", 1.0, 0.2)
	trump_icon_tween.parallel().tween_property(trump_suit_icon, "scale", Vector2(1.12, 1.12), 0.2)
	trump_icon_tween.tween_property(trump_suit_icon, "scale", Vector2.ONE, 0.12)

func _get_sort_rank_value(rank: String) -> int:
	match rank.to_lower():
		"ace":
			return 14
		"king":
			return 13
		"queen":
			return 12
		"jack":
			return 11
		"10":
			return 10
		"9":
			return 9
		"8":
			return 8
		"7":
			return 7
		"6":
			return 6
		"5":
			return 5
		"4":
			return 4
		"3":
			return 3
		"2":
			return 2
		_:
			return 0


func _get_alternating_suit_order() -> Array:
	# black, red, black, red
	return ["spades", "hearts", "clubs", "diamonds"]


func _get_arrange_suit_order() -> Array:
	var base_order: Array = _get_alternating_suit_order()

	if trump_active and trump_suit != "":
		var ordered: Array = [trump_suit.to_lower()]
		for suit in base_order:
			if suit != trump_suit.to_lower():
				ordered.append(suit)
		return ordered

	return base_order


func _get_suit_sort_value(suit: String) -> int:
	var order: Array = _get_arrange_suit_order()
	return order.find(suit.to_lower())
	
func _arrange_my_hand() -> void:
	if my_hand_cards.is_empty():
		return

	my_hand_cards.sort_custom(func(a, b):
		var suit_a: int = _get_suit_sort_value(a.suit)
		var suit_b: int = _get_suit_sort_value(b.suit)

		if suit_a != suit_b:
			return suit_a < suit_b

		var rank_a: int = _get_sort_rank_value(a.rank)
		var rank_b: int = _get_sort_rank_value(b.rank)

		return rank_a > rank_b
	)

	_layout_hand(my_hand_cards, "my")
	_sync_runtime_hand_order_to_state("my", my_hand_cards)
	
func _on_arrange_button_pressed() -> void:
	my_hand_is_arranged = true
	_arrange_my_hand()

#func _submit_player_action(action: Dictionary) -> void:
	## Local/offline mode: no multiplayer peer connected yet
	#if multiplayer.multiplayer_peer == null:
		#await _process_action(action)
		#return
#
	#if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		#await _process_action(action)
		#return
#
	## Online mode
	#if multiplayer.is_server():
		#await _process_action(action)
		#rpc("_remote_apply_action", action)
	#else:
		#rpc_id(1, "_server_receive_action", action)
func _submit_player_action(action: Dictionary) -> void:
	if is_server_authoritative_match or not is_match_host:
		NetworkManager.send_game_action(action)
		return

	await _process_action(action)

func _on_game_action_received(action: Dictionary) -> void:
	if not is_match_host:
		return

	var host_action := action.duplicate(true)
	var abs_seat_id := str(host_action.get("abs_seat_id", ""))
	if abs_seat_id != "":
		host_action["seat"] = _get_local_view_from_abs_seat_id(abs_seat_id)

	await _process_action(host_action)

func _process_action(action: Dictionary) -> void:
	if not action.has("type"):
		return

	match action["type"]:
		"play_card":
			await _handle_play_card_action(action)
		"open_trump":
			await _handle_open_trump_action(action)
		"confirm_hidden_trump":
			await _handle_confirm_hidden_trump_action(action)

func _find_card_in_hand_by_id(hand_array: Array, card_id: String) -> Node3D:
	for card in hand_array:
		if card.card_id == card_id:
			return card
	return null
	
func _handle_play_card_action(action: Dictionary) -> void:
	if not action.has("seat") or not action.has("card_id"):
		return

	var seat: String = action["seat"]
	var card_id: String = str(action["card_id"])

	if trick_is_resolving:
		return

	if trump_reveal_in_progress:
		return

	if _get_current_turn_seat() != seat:
		return

	var hand_array: Array = []
	var slot_pos := Vector3.ZERO
	var slot_rot := Vector3.ZERO
	var is_human_seat: bool = (seat == "my")

	match seat:
		"my":
			hand_array = my_hand_cards
			slot_pos = slot0_bottom.position
			slot_rot = Vector3(90, 0, 0)
		"right":
			hand_array = right_hand_cards
			slot_pos = slot1_right.position
			slot_rot = Vector3(90, 0, -20)
		"top":
			hand_array = top_hand_cards
			slot_pos = slot2_top.position
			slot_rot = Vector3(90, 0, 0)
		"left":
			hand_array = left_hand_cards
			slot_pos = slot3_left.position
			slot_rot = Vector3(90, 0, 20)
		_:
			return

	var card: Node3D = _find_card_in_hand_by_id(hand_array, card_id)
	if card == null:
		return

	if not _is_card_legal_for_hand(card, hand_array):
		print("Illegal move for seat ", seat, ". Lead suit is: ", current_lead_suit, " | Selected: ", card.suit)
		return

	if seat == "my":
		if not _is_card_legal_after_hidden_trump_reveal(card, my_hand_cards):
			print("Illegal move after hidden trump reveal. Must play trump suit: ", trump_suit)
			return
	else:
		if trump_mode == "hidden" and trump_active and awaiting_hidden_trump_play and seat == hidden_trump_holder_seat:
			if _hand_has_suit(hand_array, trump_suit) and card.suit.to_lower() != trump_suit.to_lower():
				print("Illegal bot/opponent move after hidden trump reveal. Must play trump suit: ", trump_suit)
				return

	var was_void_in_lead_suit: bool = false
	if current_lead_suit != "":
		was_void_in_lead_suit = not _hand_has_suit(hand_array, current_lead_suit)

	var auto_opened_trump: bool = false
	if trump_mode == "open":
		auto_opened_trump = _maybe_activate_open_trump(card, was_void_in_lead_suit)

	_stop_turn_timer()

	var removed_card_state: Dictionary = _remove_card_from_state_hand(seat, card_id)
	if removed_card_state.is_empty():
		print("State hand removal failed for seat ", seat, " card ", card_id)
		return

	hand_array.erase(card)
	card.clickable = false
	card.played = true

	var my_generation: int = state_restore_generation
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", slot_pos, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", slot_rot, 0.35)

	await tween.finished

	if my_generation != state_restore_generation:
		return
	if not is_instance_valid(card):
		return

	if seat != "my":
		card.flip_card()

	var was_trump_at_play_time: bool = auto_opened_trump or (trump_active and card.suit.to_lower() == trump_suit.to_lower())

	if current_lead_suit == "":
		current_lead_suit = card.suit

	game_state["current_lead_suit"] = current_lead_suit
	_append_trick_card_to_state(seat, card, was_trump_at_play_time)

	var trick_entry := {
		"seat": seat,
		"card": card,
		"was_trump_at_play_time": was_trump_at_play_time
	}

	trick_cards.append(trick_entry)
	trick_slots_filled[seat] = true

	_set_turn_state_in_game_state()
	_sync_game_state_to_runtime()

	if seat == "my" and selected_card == card:
		selected_card = null

	if seat == "right":
		_layout_hand(right_hand_cards, "right")
	elif seat == "top":
		_layout_hand(top_hand_cards, "top")
	elif seat == "left":
		_layout_hand(left_hand_cards, "left")
	elif seat == "my":
		_layout_hand(my_hand_cards, "my")

	print(seat, " played ", card.suit, " ", card.rank, " | lead suit: ", current_lead_suit, " | trump active: ", trump_active, " | trump suit: ", trump_suit)

	if seat == "my":
		awaiting_hidden_trump_play = false
		seat_timeout_autoplay["my"] = false
	else:
		seat_timeout_autoplay[seat] = false

	_refresh_action_buttons()
	_sync_runtime_to_game_state()
	if is_match_host:
		_broadcast_full_game_state()
	await _after_seat_played()


func _handle_open_trump_action(action: Dictionary) -> void:
	if not action.has("seat"):
		return
	var my_generation: int = state_restore_generation
	var seat: String = action["seat"]

	if trick_is_resolving:
		return

	if trump_reveal_in_progress:
		return

	if _get_current_turn_seat() != seat:
		return

	if seat != "my":
		return

	if not _can_my_hand_open_hidden_trump():
		print("Cannot open hidden trump now")
		return

	if hidden_trump_card_data.is_empty():
		print("No hidden trump card assigned")
		return

	if selected_card != null:
		selected_card.set_selected(false)
		selected_card = null

	_stop_turn_timer()

	trump_active = true
	trump_suit = hidden_trump_card_data["suit"]
	hidden_trump_revealed = true
	awaiting_hidden_trump_play = true
	game_state["trump_active"] = true
	game_state["trump_suit"] = trump_suit
	game_state["hidden_trump_revealed"] = true
	game_state["awaiting_hidden_trump_play"] = true
	_mark_hidden_trump_revealed_in_state()
	_sync_game_state_to_runtime()
	game_state["trump_active"] = true
	game_state["trump_suit"] = trump_suit
	game_state["hidden_trump_revealed"] = true
	game_state["awaiting_hidden_trump_play"] = true
	game_state["hidden_trump_card_data"] = hidden_trump_card_data.duplicate()
	_sync_game_state_to_runtime()
	trump_reveal_in_progress = true
	_refresh_trump_label()
	_refresh_action_buttons()

	print("Hidden trump revealed by my: ", hidden_trump_card_data["suit"], " ", hidden_trump_card_data["rank"])

	_show_hidden_trump_reveal()
	_show_trump_opened_message()

	await get_tree().create_timer(6.0).timeout

	if my_generation != state_restore_generation:
		return
	if hidden_trump_card_node != null and not is_instance_valid(hidden_trump_card_node):
		return

	await _return_hidden_trump_to_holder_hand()

	if my_generation != state_restore_generation:
		return

	trump_reveal_in_progress = false
	_refresh_trump_suit_icon()
	_animate_trump_suit_icon_in()
	_clear_phase_message_if_not_selecting()

	print("Now choose a card to play after hidden trump reveal.")
	_sync_runtime_to_game_state()
	_start_turn_timer_for_current_seat()
	_refresh_action_buttons()
	if is_match_host:
		_broadcast_full_game_state()
		
func _handle_confirm_hidden_trump_action(action: Dictionary) -> void:
	if not action.has("seat") or not action.has("card_id"):
		return

	var seat: String = action["seat"]
	var card_id: String = str(action["card_id"])
	var my_generation: int = state_restore_generation
	if not selecting_hidden_trump:
		return

	if seat != "my":
		return

	if hidden_trump_holder_seat != "my":
		return

	var card: Node3D = _find_card_in_hand_by_id(my_hand_cards, card_id)
	if card == null:
		return

	hidden_trump_card_data = {
		"card_id": card.card_id,
		"suit": card.suit,
		"rank": card.rank
	}
	hidden_trump_revealed = false
	hidden_trump_card_node = card

	_set_hidden_trump_in_state(card, "my")
	game_state["hidden_trump_revealed"] = false
	game_state["awaiting_hidden_trump_play"] = false

	print("Hidden trump chosen by my: ", hidden_trump_card_data["suit"], " ", hidden_trump_card_data["rank"])

	var removed_card_state: Dictionary = _remove_card_from_state_hand("my", card.card_id)
	if removed_card_state.is_empty():
		print("Failed to remove hidden trump card from state hand")
		return
	my_hand_cards.erase(card)

	card.set_selected(false)
	card.clickable = false
	card.played = false
	card.set_face_up(false)

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "position", hidden_trump_slot.position, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", Vector3(90, 0, 0), 0.35)

	await tween.finished

	if my_generation != state_restore_generation:
		return
	if not is_instance_valid(card):
		return

	selected_card = null
	selecting_hidden_trump = false
	_refresh_phase_message()
	_refresh_hidden_trump_selection_ui()
	_layout_hand(my_hand_cards, "my")
	if is_match_host:
		_broadcast_full_game_state()
	
	
func _get_legal_card_id_for_seat(seat_name: String) -> String:
	var hand_array: Array = _hand_array_for_view(seat_name)

	if hand_array.is_empty():
		return ""

	var legal_index: int = -1

	if seat_name == "my" and trump_mode == "hidden" and trump_active and awaiting_hidden_trump_play:
		var trump_index: int = _get_first_card_index_of_suit(hand_array, trump_suit)
		if trump_index != -1:
			legal_index = trump_index
		else:
			legal_index = _get_first_legal_card_index(hand_array)
	elif seat_name != "my" and trump_mode == "hidden" and trump_active and awaiting_hidden_trump_play and seat_name == hidden_trump_holder_seat:
		var trump_index: int = _get_first_card_index_of_suit(hand_array, trump_suit)
		if trump_index != -1:
			legal_index = trump_index
		else:
			legal_index = _get_first_legal_card_index(hand_array)
	else:
		legal_index = _get_first_legal_card_index(hand_array)

	if legal_index == -1:
		return ""

	return hand_array[legal_index].card_id
	
func _create_initial_game_state() -> Dictionary:
	return {
		"dealer_seat": dealer_seat,
		"hidden_trump_holder_seat": hidden_trump_holder_seat,
		"current_leader_index": current_leader_index,
		"current_turn_index": current_turn_index,
		"current_lead_suit": "",
		"trick_in_progress": false,
		"trick_is_resolving": false,

		"trump_mode": trump_mode,
		"trump_active": false,
		"trump_suit": "",
		"hidden_trump_revealed": false,
		"awaiting_hidden_trump_play": false,

		"hidden_trump": {
			"card_id": "",
			"suit": "",
			"rank": "",
			"holder_seat": hidden_trump_holder_seat,
			"is_set_aside": false,
			"is_revealed": false,
			"has_returned_to_hand": false
		},

		"team_a_trick_count": 0,
		"team_b_trick_count": 0,

		"hands": {
			"my": [],
			"right": [],
			"top": [],
			"left": []
		},

		"trick_cards": []
	}
	
func _sync_runtime_to_game_state() -> void:
	game_state["dealer_seat"] = dealer_seat
	game_state["hidden_trump_holder_seat"] = hidden_trump_holder_seat
	game_state["current_leader_index"] = current_leader_index
	game_state["current_turn_index"] = current_turn_index
	game_state["current_lead_suit"] = current_lead_suit
	game_state["trick_in_progress"] = trick_in_progress
	game_state["trick_is_resolving"] = trick_is_resolving

	game_state["trump_mode"] = trump_mode
	game_state["trump_active"] = trump_active
	game_state["trump_suit"] = trump_suit
	game_state["hidden_trump_revealed"] = hidden_trump_revealed
	game_state["awaiting_hidden_trump_play"] = awaiting_hidden_trump_play
	game_state["hidden_trump_card_data"] = hidden_trump_card_data.duplicate()
	game_state["team_a_trick_count"] = team_a_trick_count
	game_state["team_b_trick_count"] = team_b_trick_count

	game_state["hands"]["my"] = _cards_to_state_array(my_hand_cards)
	game_state["hands"]["right"] = _cards_to_state_array(right_hand_cards)
	game_state["hands"]["top"] = _cards_to_state_array(top_hand_cards)
	game_state["hands"]["left"] = _cards_to_state_array(left_hand_cards)

	game_state["trick_cards"] = _trick_cards_to_state_array()
	
func _cards_to_state_array(hand_array: Array) -> Array:
	var result: Array = []

	for card in hand_array:
		result.append({
			"card_id": card.card_id,
			"suit": card.suit,
			"rank": card.rank,
			"is_face_up": card.is_face_up
		})

	return result
	
func _trick_cards_to_state_array() -> Array:
	var result: Array = []

	for entry in trick_cards:
		var card: Node3D = entry["card"]
		result.append({
			"seat": entry["seat"],
			"card_id": card.card_id,
			"suit": card.suit,
			"rank": card.rank,
			"was_trump_at_play_time": entry.get("was_trump_at_play_time", false)
		})

	return result
	
func _debug_print_game_state() -> void:
	print("=== GAME STATE ===")
	print(game_state)

func _sync_game_state_to_runtime() -> void:
	current_match_phase = str(game_state.get("phase", current_match_phase))
	trump_holder_abs_seat_id = str(game_state.get("trump_holder_seat_id", trump_holder_abs_seat_id))
	dealer_seat = game_state.get("dealer_seat", dealer_seat)
	hidden_trump_holder_seat = game_state.get("hidden_trump_holder_seat", hidden_trump_holder_seat)
	current_leader_index = game_state.get("current_leader_index", current_leader_index)
	current_turn_index = game_state.get("current_turn_index", current_turn_index)
	current_lead_suit = game_state.get("current_lead_suit", current_lead_suit)
	trick_in_progress = game_state.get("trick_in_progress", trick_in_progress)
	trick_is_resolving = game_state.get("trick_is_resolving", trick_is_resolving)

	trump_mode = game_state.get("trump_mode", trump_mode)
	trump_active = game_state.get("trump_active", trump_active)
	trump_suit = game_state.get("trump_suit", trump_suit)
	hidden_trump_revealed = game_state.get("hidden_trump_revealed", hidden_trump_revealed)
	awaiting_hidden_trump_play = game_state.get("awaiting_hidden_trump_play", awaiting_hidden_trump_play)

	var ht: Dictionary = game_state.get("hidden_trump", {})
	if not ht.is_empty():
		hidden_trump_card_data = {
			"card_id": ht.get("card_id", ""),
			"suit": ht.get("suit", ""),
			"rank": ht.get("rank", "")
		}
	team_a_trick_count = game_state.get("team_a_trick_count", team_a_trick_count)
	team_b_trick_count = game_state.get("team_b_trick_count", team_b_trick_count)
	selecting_hidden_trump = current_match_phase == "closed_trump_card_choice"
	input_phase_active = current_match_phase == "playing"

func _set_turn_state_in_game_state() -> void:
	game_state["dealer_seat"] = dealer_seat
	game_state["hidden_trump_holder_seat"] = hidden_trump_holder_seat
	game_state["current_leader_index"] = current_leader_index
	game_state["current_turn_index"] = current_turn_index
	game_state["current_lead_suit"] = current_lead_suit
	game_state["trick_in_progress"] = trick_in_progress
	game_state["trick_is_resolving"] = trick_is_resolving

	game_state["trump_mode"] = trump_mode
	game_state["trump_active"] = trump_active
	game_state["trump_suit"] = trump_suit
	game_state["hidden_trump_revealed"] = hidden_trump_revealed
	game_state["awaiting_hidden_trump_play"] = awaiting_hidden_trump_play
	game_state["hidden_trump_card_data"] = hidden_trump_card_data.duplicate()
	game_state["team_a_trick_count"] = team_a_trick_count
	game_state["team_b_trick_count"] = team_b_trick_count
	
func _remove_card_from_state_hand(seat_name: String, card_id: String) -> Dictionary:
	if not game_state.has("hands"):
		return {}

	if not game_state["hands"].has(seat_name):
		return {}

	var hand_state: Array = game_state["hands"][seat_name]

	for i in range(hand_state.size()):
		var card_state: Dictionary = hand_state[i]
		if str(card_state.get("card_id", "")) == card_id:
			hand_state.remove_at(i)
			game_state["hands"][seat_name] = hand_state
			return card_state

	return {}
	
func _append_card_to_state_hand(seat_name: String, card_state: Dictionary) -> void:
	if not game_state.has("hands"):
		return

	if not game_state["hands"].has(seat_name):
		game_state["hands"][seat_name] = []

	var hand_state: Array = game_state["hands"][seat_name]
	hand_state.append(card_state)
	game_state["hands"][seat_name] = hand_state
	
func _get_runtime_hand_array(seat_name: String) -> Array:
	return _hand_array_for_view(seat_name)
			
func _sync_runtime_hand_order_to_state(seat_name: String, hand_array: Array) -> void:
	if not game_state.has("hands"):
		return

	var state_cards: Array = game_state["hands"].get(seat_name, [])
	if state_cards.is_empty():
		return

	var state_by_id := {}
	for entry in state_cards:
		state_by_id[str(entry.get("card_id", ""))] = entry

	var reordered: Array = []
	for card in hand_array:
		var cid: String = str(card.card_id)
		if state_by_id.has(cid):
			reordered.append(state_by_id[cid])

	game_state["hands"][seat_name] = reordered

func _append_trick_card_to_state(seat_name: String, card: Node3D, was_trump_at_play_time: bool) -> void:
	if not game_state.has("trick_cards"):
		game_state["trick_cards"] = []

	var state_entry := {
		"seat": seat_name,
		"card_id": card.card_id,
		"suit": card.suit,
		"rank": card.rank,
		"was_trump_at_play_time": was_trump_at_play_time
	}

	var trick_state: Array = game_state["trick_cards"]
	trick_state.append(state_entry)
	game_state["trick_cards"] = trick_state
	
func _clear_trick_state() -> void:
	game_state["trick_cards"] = []
	
func _get_state_trick_cards() -> Array:
	return game_state.get("trick_cards", [])
	
func _clear_trick_after_capture() -> void:
	_clear_trick_state()
	game_state["current_lead_suit"] = ""
	
func _debug_print_state_trick() -> void:
	print("=== STATE TRICK ===")
	for entry in _get_state_trick_cards():
		print(entry["seat"], " played ", entry["suit"], " ", entry["rank"], " | trump_at_play=", entry.get("was_trump_at_play_time", false))
	
func _set_hidden_trump_in_state(card: Node3D, holder_seat: String) -> void:
	game_state["hidden_trump"] = {
		"card_id": card.card_id,
		"suit": card.suit,
		"rank": card.rank,
		"holder_seat": holder_seat,
		"is_set_aside": true,
		"is_revealed": false,
		"has_returned_to_hand": false
	}


func _mark_hidden_trump_revealed_in_state() -> void:
	if not game_state.has("hidden_trump"):
		return

	var ht: Dictionary = game_state["hidden_trump"]
	ht["is_revealed"] = true
	game_state["hidden_trump"] = ht


func _mark_hidden_trump_returned_in_state() -> void:
	if not game_state.has("hidden_trump"):
		return

	var ht: Dictionary = game_state["hidden_trump"]
	ht["is_set_aside"] = false
	ht["has_returned_to_hand"] = true
	game_state["hidden_trump"] = ht

func _debug_print_hidden_trump_state() -> void:
	print("=== HIDDEN TRUMP STATE ===")
	print(game_state.get("hidden_trump", {}))
	
func _clear_all_card_visuals() -> void:
	for child in cards_node.get_children():
		child.queue_free()

	my_hand_cards.clear()
	right_hand_cards.clear()
	top_hand_cards.clear()
	left_hand_cards.clear()
	for view_name in extra_hand_arrays.keys():
		(extra_hand_arrays[view_name] as Array).clear()
	trick_cards.clear()

	hidden_trump_card_node = null
	card_nodes_by_id.clear()
	
func _create_card_from_state(card_state: Dictionary, face_up: bool) -> Node3D:
	var card = _create_card()
	card.set_card_data(card_state)
	card.set_face_up(face_up)
	card.clickable = false
	card.played = false

	card_nodes_by_id[card.card_id] = card
	return card
	
func _rebuild_hand_from_state(seat_name: String) -> void:
	if not game_state.has("hands"):
		return

	var hand_state: Array = game_state["hands"].get(seat_name, [])
	var runtime_hand: Array = _hand_array_for_view(seat_name)

	runtime_hand.clear()

	for card_state in hand_state:
		var face_up: bool = (seat_name == "my")
		var card = _create_card_from_state(card_state, face_up)
		card.clickable = (seat_name == "my")

		if seat_name == "my":
			card.card_clicked.connect(_on_card_clicked)
			card.play_position = _get_trick_slot_position("my")
			card.play_rotation = Vector3(90, 0, 0)

		runtime_hand.append(card)

	_layout_hand(runtime_hand, seat_name)

	if seat_name == "my" and my_hand_is_arranged:
		_arrange_my_hand()


func _rebuild_hidden_trump_from_state() -> void:
	var ht: Dictionary = game_state.get("hidden_trump", {})
	if ht.is_empty():
		return

	var card_id: String = str(ht.get("card_id", ""))
	if card_id == "":
		return

	# If hidden trump is already back in hand, do not show it in slot
	if ht.get("has_returned_to_hand", false):
		return

	# Create visual card in hidden trump slot
	var card_state := {
		"id": card_id.to_int() if card_id.is_valid_int() else card_id,
		"card_id": card_id,
		"suit": str(ht.get("suit", "")),
		"rank": str(ht.get("rank", ""))
	}

	var card = _create_card_from_state(card_state, ht.get("is_revealed", false))
	card.position = hidden_trump_slot.position
	card.rotation_degrees = Vector3(90, 0, 0)
	card.clickable = false
	hidden_trump_card_node = card
	
func _rebuild_trick_from_state() -> void:
	var trick_state: Array = game_state.get("trick_cards", [])
	trick_cards.clear()

	for entry in trick_state:
		var seat: String = str(entry.get("seat", ""))
		var card_state := {
			"id": entry.get("card_id", ""),
			"card_id": str(entry.get("card_id", "")),
			"suit": str(entry.get("suit", "")),
			"rank": str(entry.get("rank", ""))
		}

		var card = _create_card_from_state(card_state, true)
		card.played = true
		card.clickable = false

		card.position = _get_trick_slot_position(seat)
		card.rotation_degrees = _get_play_rotation_for_view(seat)

		trick_cards.append({
			"seat": seat,
			"card": card,
			"was_trump_at_play_time": entry.get("was_trump_at_play_time", false)
		})
		

func _sync_player_count_from_state() -> void:
	var snap_count := int(game_state.get("player_count", 0))
	if snap_count == 0:
		snap_count = (game_state.get("hands", {}) as Dictionary).size()
	if snap_count != 4 and snap_count != 6 and snap_count != 8:
		return
	if snap_count == current_player_count and seat_order.size() == snap_count:
		return
	current_player_count = snap_count
	seat_order = ALL_VIEWS.slice(0, snap_count)
	_build_local_view_mapping()
	_ensure_nameplates()

func _apply_seat_info_from_state() -> void:
	var info: Dictionary = game_state.get("seat_info", {})
	for view_key in info.keys():
		var view_name := str(view_key)
		var entry: Dictionary = info[view_key]
		var existing: Dictionary = seat_to_player.get(view_name, {})
		existing["name"] = str(entry.get("name", existing.get("name", "Player")))
		existing["is_bot"] = bool(entry.get("is_bot", false))
		existing["is_connected"] = bool(entry.get("is_connected", true))
		existing["seat_id"] = str(entry.get("seat_id", existing.get("seat_id", "")))
		seat_to_player[view_name] = existing
		seat_is_bot[view_name] = bool(entry.get("is_bot", false))

func _apply_game_state_to_scene() -> void:
	_sync_game_state_to_runtime()
	_sync_player_count_from_state()
	_apply_seat_info_from_state()
	_clear_all_card_visuals()

	for view_name in seat_order:
		_rebuild_hand_from_state(str(view_name))

	_rebuild_hidden_trump_from_state()
	_rebuild_trick_from_state()

	_refresh_trump_label()
	_refresh_trump_suit_icon()

	if trump_active and trump_suit != "":
		trump_suit_icon.visible = true
	else:
		trump_suit_icon.visible = false

	if current_match_phase == "trump_mode_choice":
		input_phase_active = false
		_show_trump_mode_choice_if_needed()
	elif selecting_hidden_trump:
		input_phase_active = false
	else:
		input_phase_active = current_match_phase == "playing"

	_refresh_phase_message()
	_refresh_hidden_trump_selection_ui()
	_refresh_action_buttons()
	_refresh_scoreboard()

	for k in seat_timeout_autoplay.keys():
		seat_timeout_autoplay[k] = false

	if input_phase_active and not trick_is_resolving:
		_start_turn_timer_for_current_seat()
	else:
		_stop_turn_timer()
	_refresh_turn_timer_label()

func _debug_rebuild_scene_from_state() -> void:
	print("Rebuilding scene from game_state...")
	_begin_scene_rebuild()
	_apply_game_state_to_scene()
	_end_scene_rebuild()

func _can_rebuild_from_state_now() -> bool:
	if scene_rebuild_in_progress:
		return false
	if selecting_hidden_trump:
		return false
	if trump_reveal_in_progress:
		return false
	if trick_is_resolving:
		return false
	if not input_phase_active:
		return false
	return true

	
func _begin_scene_rebuild() -> void:
	scene_rebuild_in_progress = true
	state_restore_generation += 1
	_stop_turn_timer()
	
func _end_scene_rebuild() -> void:
	scene_rebuild_in_progress = false
	_refresh_action_buttons()
	_refresh_phase_message()
	_refresh_turn_timer_label()


func _load_match_setup() -> Dictionary:
	var config := ConfigFile.new()
	var err := config.load("user://match_setup.cfg")
	if err != OK:
		return {}
	return config.get_value("match", "setup", {})



func _apply_bot_flags_from_seats() -> void:
	for seat_name in seat_order:
		var p: Dictionary = seat_to_player.get(seat_name, {})
		seat_is_bot[seat_name] = bool(p.get("is_bot", false))

func _seat_index_from_id(seat_id: String) -> int:
	if seat_id.begins_with("seat_"):
		return int(seat_id.trim_prefix("seat_"))
	return 0

func _build_local_view_mapping() -> void:
	local_view_to_abs = {}
	abs_to_local_view.clear()

	if local_seat_id == "":
		local_seat_id = "seat_0"

	var n := _valid_player_count(current_player_count)
	var local_index: int = _seat_index_from_id(local_seat_id)

	for offset in range(n):
		var abs_index := (local_index + offset) % n
		var abs_seat_id := "seat_%d" % abs_index
		var view_name: String = ALL_VIEWS[offset]
		local_view_to_abs[view_name] = abs_seat_id
		abs_to_local_view[abs_seat_id] = view_name

func _on_game_state_snapshot_received(snapshot: Dictionary) -> void:
	if is_match_host and not is_server_authoritative_match:
		return

	game_state = snapshot.get("game_state", {}).duplicate(true)
	has_received_initial_snapshot = true

	_sync_game_state_to_runtime()
	_apply_game_state_to_scene()


func _get_view_mapping_for_abs_seat(abs_seat_id: String) -> Dictionary:
	var mapping := {}
	if abs_seat_id == "":
		abs_seat_id = "seat_0"

	var n := _valid_player_count(current_player_count)
	var local_index := _seat_index_from_id(abs_seat_id)
	for offset in range(n):
		var abs_index := (local_index + offset) % n
		mapping["seat_%d" % abs_index] = ALL_VIEWS[offset]
	return mapping

func _remap_view_name_for_snapshot(view_name: String, target_abs_seat_id: String) -> String:
	var source_abs := str(local_view_to_abs.get(view_name, view_name))
	var target_abs_to_view := _get_view_mapping_for_abs_seat(target_abs_seat_id)
	return str(target_abs_to_view.get(source_abs, view_name))

func _remap_turn_index_for_snapshot(source_index: int, target_abs_seat_id: String) -> int:
	if source_index < 0 or source_index >= seat_order.size():
		return source_index

	var source_view: String = seat_order[source_index]
	var target_view := _remap_view_name_for_snapshot(source_view, target_abs_seat_id)
	return seat_order.find(target_view)

func _build_snapshot_for_abs_seat(target_abs_seat_id: String) -> Dictionary:
	var remapped := game_state.duplicate(true)

	if remapped.has("hands"):
		var source_hands: Dictionary = remapped["hands"]
		var target_hands := {}
		for view_name in source_hands.keys():
			var target_view := _remap_view_name_for_snapshot(str(view_name), target_abs_seat_id)
			target_hands[target_view] = source_hands[view_name]
		remapped["hands"] = target_hands

	if remapped.has("trick_cards"):
		var source_trick: Array = remapped["trick_cards"]
		var target_trick: Array = []
		for entry_raw in source_trick:
			var entry: Dictionary = entry_raw.duplicate(true)
			entry["seat"] = _remap_view_name_for_snapshot(str(entry.get("seat", "")), target_abs_seat_id)
			target_trick.append(entry)
		remapped["trick_cards"] = target_trick

	for key in ["dealer_seat", "hidden_trump_holder_seat"]:
		if remapped.has(key):
			remapped[key] = _remap_view_name_for_snapshot(str(remapped[key]), target_abs_seat_id)

	if remapped.has("hidden_trump"):
		var hidden_trump: Dictionary = remapped["hidden_trump"]
		if hidden_trump.has("holder_seat"):
			hidden_trump["holder_seat"] = _remap_view_name_for_snapshot(str(hidden_trump["holder_seat"]), target_abs_seat_id)
		remapped["hidden_trump"] = hidden_trump

	remapped["current_leader_index"] = _remap_turn_index_for_snapshot(int(remapped.get("current_leader_index", current_leader_index)), target_abs_seat_id)
	remapped["current_turn_index"] = _remap_turn_index_for_snapshot(int(remapped.get("current_turn_index", current_turn_index)), target_abs_seat_id)

	return {
		"game_state": remapped
	}

func _build_snapshots_by_peer() -> Dictionary:
	var snapshots := {}
	for view_name in seat_order:
		var p: Dictionary = seat_to_player.get(view_name, {})
		if bool(p.get("is_bot", false)):
			continue

		var peer_id := int(p.get("peer_id", 0))
		if peer_id <= 0:
			continue

		var abs_seat_id := str(p.get("seat_id", local_view_to_abs.get(view_name, "")))
		snapshots[str(peer_id)] = _build_snapshot_for_abs_seat(abs_seat_id)

	return snapshots

func _broadcast_full_game_state() -> void:
	if not is_match_host:
		return

	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	_sync_runtime_to_game_state()

	NetworkManager.send_game_state_snapshots(_build_snapshots_by_peer())


func _get_local_view_from_abs_seat_id(abs_seat_id: String) -> String:
	return str(abs_to_local_view.get(abs_seat_id, "my"))

func _get_reveal_slot_position(view_name: String) -> Vector3:
	return _get_trick_slot_position(view_name)

func _apply_match_phase_setup(match_setup: Dictionary) -> void:
	current_match_phase = str(match_setup.get("phase", ""))
	dealer_draw_cards = match_setup.get("dealer_draw_cards", []).duplicate(true)
	trump_holder_abs_seat_id = str(match_setup.get("trump_holder_seat_id", ""))
	var setup_trump_mode := str(match_setup.get("trump_mode", ""))
	if setup_trump_mode != "":
		trump_mode = setup_trump_mode


func _build_dealer_draw_cards() -> void:
	_clear_all_card_visuals()
	dealer_draw_card_nodes_by_index.clear()
	dealer_draw_claimed_animated.clear()
	dealer_draw_visual_cards.clear()
	my_hand_cards.clear()
	right_hand_cards.clear()
	top_hand_cards.clear()
	left_hand_cards.clear()

	var center_pos: Vector3 = TRICK_RING_CENTER
	var total_cards: int = dealer_draw_cards.size()
	var draw_spacing := 0.6 if total_cards <= 6 else 0.5

	for card_state_raw in dealer_draw_cards:
		var card_state: Dictionary = card_state_raw
		var draw_index: int = int(card_state.get("draw_index", 0))

		var card := _create_card()
		card.set_card_data({
			"card_id": "dealer_draw_%s" % str(draw_index),
			"suit": str(card_state.get("suit", "")),
			"rank": str(card_state.get("rank", ""))
		})

		card.set_face_up(false)
		card.clickable = not bool(card_state.get("is_claimed", false))
		card.position = center_pos + Vector3((float(draw_index) - (float(total_cards) - 1.0) / 2.0) * draw_spacing, 0, 0)
		card.rotation_degrees = Vector3(90, 0, 0)

		if card.clickable:
			card.card_clicked.connect(func(clicked_card):
				_on_dealer_draw_card_clicked(clicked_card, draw_index)
			)

		dealer_draw_card_nodes_by_index[draw_index] = card
		dealer_draw_visual_cards.append(card)

	for card_state_raw in dealer_draw_cards:
		var card_state: Dictionary = card_state_raw
		if bool(card_state.get("is_claimed", false)):
			_place_claimed_dealer_draw_card_immediately(card_state)

func _on_dealer_draw_card_clicked(card: Node3D, draw_index: int) -> void:
	if current_match_phase != "dealer_draw":
		return
	if dealer_draw_selected_index != -1:
		return

	dealer_draw_selected_index = draw_index
	NetworkManager.claim_dealer_draw_card(draw_index)

func _move_claimed_dealer_draw_card(card_state: Dictionary) -> void:
	var draw_index: int = int(card_state.get("draw_index", 0))

	if dealer_draw_claimed_animated.get(draw_index, false):
		return

	if not dealer_draw_card_nodes_by_index.has(draw_index):
		return

	var card: Node3D = dealer_draw_card_nodes_by_index[draw_index]
	if card == null:
		return

	card.clickable = false
	card.set_face_up(true)

	var claimed_by_abs: String = str(card_state.get("claimed_by_seat_id", ""))
	var claimed_view: String = _get_local_view_from_abs_seat_id(claimed_by_abs)
	var target_pos: Vector3 = _get_reveal_slot_position(claimed_view)

	var tween := create_tween()
	tween.parallel().tween_property(card, "position", target_pos, 0.35)
	tween.parallel().tween_property(card, "rotation_degrees", Vector3(90, 0, 0), 0.35)

	dealer_draw_claimed_animated[draw_index] = true

func _show_trump_mode_choice_if_needed() -> void:
	if current_match_phase != "trump_mode_choice":
		return

	var local_abs_seat_id: String = str(local_view_to_abs.get("my", ""))
	var is_trump_holder: bool = (local_abs_seat_id == trump_holder_abs_seat_id)

	phase_message_panel.visible = true

	if is_trump_holder:
		phase_message_label.text = "Choose Closed Trump or Open Trump"
		confirm_hidden_trump_button.visible = true
		confirm_hidden_trump_button.disabled = false
		confirm_hidden_trump_button.text = "Closed Trump"
		open_trump_button.visible = true
		open_trump_button.disabled = false
		open_trump_button.text = "Open Trump"
	else:
		phase_message_label.text = "Waiting for %s to choose trump mode." % _get_display_name_for_seat(_get_local_view_from_abs_seat_id(trump_holder_abs_seat_id))
		confirm_hidden_trump_button.visible = false
		confirm_hidden_trump_button.disabled = true
		open_trump_button.visible = false
		open_trump_button.disabled = true

func _on_network_dealer_draw_updated(match_data: Dictionary) -> void:
	_apply_match_phase_setup(match_data)

	if dealer_draw_card_nodes_by_index.is_empty():
		_build_dealer_draw_cards()
		return

	for card_state_raw in dealer_draw_cards:
		var card_state: Dictionary = card_state_raw
		if bool(card_state.get("is_claimed", false)):
			_move_claimed_dealer_draw_card(card_state)

func _on_network_trump_mode_choice_requested(match_data: Dictionary) -> void:
	_apply_match_phase_setup(match_data)

	if dealer_draw_card_nodes_by_index.is_empty():
		_build_dealer_draw_cards()
	else:
		for card_state_raw in dealer_draw_cards:
			var card_state: Dictionary = card_state_raw
			if bool(card_state.get("is_claimed", false)):
				_move_claimed_dealer_draw_card(card_state)

	_show_trump_mode_choice_if_needed()

func _place_claimed_dealer_draw_card_immediately(card_state: Dictionary) -> void:
	var draw_index: int = int(card_state.get("draw_index", 0))
	if not dealer_draw_card_nodes_by_index.has(draw_index):
		return

	var card: Node3D = dealer_draw_card_nodes_by_index[draw_index]
	if card == null:
		return

	card.clickable = false
	card.set_face_up(true)

	var claimed_by_abs: String = str(card_state.get("claimed_by_seat_id", ""))
	var claimed_view: String = _get_local_view_from_abs_seat_id(claimed_by_abs)

	card.position = _get_reveal_slot_position(claimed_view)
	card.rotation_degrees = Vector3(90, 0, 0)
	dealer_draw_claimed_animated[draw_index] = true
