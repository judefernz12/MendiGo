extends Node3D

# Server-authoritative table renderer.
#
# The server owns the game. This script only draws what the server reports and
# animates the difference between the last drawn state and the new one, so
# cards are never re-created (and therefore never re-dealt) unless something
# actually changed. A full snap-rebuild is only used for the first paint of an
# in-progress game (reconnect) or if a delta cannot be reconciled.

const CARD_SCENE := preload("res://scenes/game/Card3D.tscn")

# View names in table order, stepping counter-clockwise from the local player.
# The server uses the same ordering when it builds per-player snapshots.
const ALL_VIEWS := ["my", "right", "top", "left", "seat4", "seat5", "seat6", "seat7"]

# Table geometry, expressed in the local space of the Cards node so every card,
# slot and pile shares one coordinate system. The 4-player values reproduce the
# original hand-placed markers.
# The ring is centred on the camera's axis (world z 1.2645, which is local
# z -0.025) so the table sits in the middle of the screen instead of drifting
# to one edge. RZ is the tight one: the local hand and the action buttons both
# have to fit below it.
const SEAT_RING_CENTER := Vector3(0, 1, -0.10)
const SEAT_RING_RX := 2.8
const SEAT_RING_RZ := 1.60

# A clear arc kept around the local player. With seats spread evenly over the
# whole circle, a 6- or 8-player table puts a neighbour right beside the local
# hand and their cards and nameplate run into it. Everyone but the local player
# is spread over what is left of the circle instead.
const BOTTOM_GAP_DEG := 78.0

# The local hand is drawn slightly larger than the rest of the table: it is the
# only one whose faces have to be read.
const MY_CARD_SCALE := 1.16

# How far the team-coloured border sticks out past a played card.
const TEAM_GLOW_SCALE := 1.16
const TRICK_RING_CENTER := Vector3(0, 1, -0.10)
const TRICK_RING_RX := 1.10
const TRICK_RING_RZ := 0.60
const CARD_FLAT_ROT := Vector3(90, 0, 0)

# A card's face, from the mesh in Card3D.tscn: width along its local X, height
# along its local Y, no meaningful thickness.
const CARD_W := 0.53
const CARD_H := 0.742

# Names are drawn just clear of the cards they belong to, in screen space, so
# they follow whatever the seat actually looks like.
const NAMEPLATE_SIZE := Vector2(140, 22)
const NAMEPLATE_GAP := 8.0

# Animation timing.
const DEAL_TIME := 0.22
const DEAL_STAGGER := 0.06
const FLIP_STAGGER := 0.05
const PLAY_TIME := 0.28
const CAPTURE_TIME := 0.42
const CAPTURE_HOLD := 0.2
const TRUMP_MOVE_TIME := 0.35
const RELAYOUT_TIME := 0.18

# Captured pile stacking (top-down camera: lift slightly and step forward).
# The z step has to stay small: 13 tricks at the old 0.13 walked the pile most
# of a card-length across the table and into the player's hand.
const PILE_Y_STEP := 0.006
const PILE_Z_STEP := 0.022
# Captured 10s are laid out in a column beside the pile, on the far side from
# the table centre.
const TEN_OUTWARD := 0.72
const TEN_SPACING := 0.26

const TURN_TIME_LIMIT := 20.0

# HUD palette. Kept here so the scoreboard, nameplates and the court
# celebration all speak the same colour language.
const COL_TEXT := Color(0.92, 0.95, 0.93)
const COL_MUTED := Color(0.60, 0.70, 0.65)
const COL_YOU := Color(0.46, 0.83, 0.60)
const COL_THEM := Color(0.95, 0.55, 0.45)
const COL_GOLD := Color(0.95, 0.83, 0.44)
# Who is on my side. Blue reads as "with me", red as "against me", which
# matters most at 6- and 8-player tables where partners are not simply
# opposite you.
const COL_TEAM_MINE := Color(0.36, 0.66, 0.98)
const COL_TEAM_THEIRS := Color(0.95, 0.42, 0.40)

const TENS_IN_DECK := 4
const COURT_CELEBRATION_TIME := 3.4

# Opponent cards are face down and carry no information, so the table shows a
# small tight bunch instead of a wide fan. The real hand size still lives on
# the server; this only limits how many card backs are drawn.
const MAX_OPPONENT_CARDS := 4
const OPPONENT_CARD_SPACING := 0.22
# Opponent cards stand upright facing the table, so stacking them with only a
# vertical offset left the faces coplanar and they z-fought - the flickering
# "glitch". Each card is pushed slightly outwards along the seat's radius
# instead, which is the direction its face points.
const OPPONENT_CARD_DEPTH := 0.012

@onready var cards_node: Node3D = $Cards
@onready var deck_point: Marker3D = $DeckPoint
@onready var hidden_trump_slot: Marker3D = $HiddenTrumpSlot
@onready var pile_team_a: Marker3D = $TeamPiles/PileTeamA
@onready var pile_team_b: Marker3D = $TeamPiles/PileTeamB
@onready var my_seat_anchor: Marker3D = $SeatAnchors/Seat0_MyHand

@onready var hud: Control = $CanvasLayer/HUD
@onready var play_button: Button = $CanvasLayer/HUD/PlayButton
@onready var confirm_hidden_trump_button: Button = $CanvasLayer/HUD/ConfirmHiddenTrumpButton
@onready var open_trump_button: Button = $CanvasLayer/HUD/OpenTrumpButton
@onready var arrange_button: Button = $CanvasLayer/HUD/ArrangeButton
@onready var trump_label: Label = $CanvasLayer/HUD/TrumpLabel
@onready var trump_suit_icon: TextureRect = $CanvasLayer/HUD/TrumpSuitIcon
@onready var turn_timer_widget: Control = $CanvasLayer/HUD/TurnTimerWidget
@onready var turn_timer_ring: TextureProgressBar = $CanvasLayer/HUD/TurnTimerWidget/TurnTimerRing
@onready var turn_timer_text: Label = $CanvasLayer/HUD/TurnTimerWidget/TurnTimerText
@onready var phase_message_panel: PanelContainer = $CanvasLayer/HUD/PhaseMessagePanel
@onready var phase_message_label: Label = $CanvasLayer/HUD/PhaseMessagePanel/PhaseMessageLabel

# --- rendered state -------------------------------------------------------

var state: Dictionary = {}           # snapshot currently drawn on the table
var pending_state: Dictionary = {}   # newest snapshot not drawn yet
var is_rendering: bool = false
var render_gen: int = 0

var local_seat_id: String = ""
var current_player_count: int = 4
var seat_order: Array = ["my", "right", "top", "left"]
var local_view_to_abs: Dictionary = {}
var abs_to_local_view: Dictionary = {}
var seat_to_player: Dictionary = {}
var my_team: String = "A"

var hand_cards: Dictionary = {}      # view name -> Array[Node3D] (drawn cards)
var seat_card_counts: Dictionary = {}  # view name -> real hand size on the server
var trick_entries: Array = []        # [{ "seat": String, "card_id": String, "node": Node3D }]
var hidden_trump_node: Node3D = null
var pile_bundles: Dictionary = {"A": [], "B": []}
var pile_ten_nodes: Dictionary = {"A": [], "B": []}

var dealer_draw_cards: Array = []
var dealer_draw_nodes: Dictionary = {}
var dealer_draw_claimed: Dictionary = {}
var dealer_draw_selected: int = -1

# --- gameplay mirror (read from snapshots, never authoritative) ------------

var phase: String = ""
var trump_holder_abs_seat_id: String = ""
var trump_holder_view: String = ""   # view name straight from the server
var trump_mode: String = ""
var trump_active: bool = false
var trump_suit: String = ""
var lead_suit: String = ""
var must_play_trump: bool = false   # I opened the trump and owe a trump card
var dealer_view: String = ""
var my_turn: bool = false
var table_busy: bool = true          # resolving / revealing / animating

var selected_card: Node3D = null
var my_hand_sorted: bool = false

var timer_active: bool = false
var timer_view: String = ""          # which seat the ring is counting down for
var turn_time_limit: float = TURN_TIME_LIMIT
var turn_time_limit_active: float = TURN_TIME_LIMIT
var time_left: float = 0.0
var timer_token: int = 0
var timer_pulse_t: float = 0.0
var timer_fade_tween: Tween = null
var trump_icon_tween: Tween = null

var nameplates: Dictionary = {}
var nameplate_styles: Dictionary = {}   # view name -> StyleBoxFlat on the plate
var turn_pulse_t: float = 0.0
var hud_values: Dictionary = {}      # scoreboard cell name -> Label
var score_panel: PanelContainer = null
var trump_panel: PanelContainer = null
var leave_button: Button = null

var court_celebrated: bool = false
var celebration_layer: Control = null

var is_host: bool = false
# Watching, not playing: no seat, no hand, nothing to click. Every seat on the
# table belongs to somebody else, including the one at the bottom.
var is_spectator: bool = false
var spectator_badge: PanelContainer = null
var team_row_labels: Dictionary = {}   # "you" / "them" -> Label
var next_game_deadline_ms: int = 0
var countdown_panel: PanelContainer = null
var countdown_label: Label = null
var action_bar: HBoxContainer = null
var reveal_glow_style: StyleBoxFlat = null
var reveal_pulse_t: float = 0.0
var trump_mode_layer: Control = null
var trump_mode_countdown: Label = null
var choice_deadline_ms: int = 0
var choice_deadline_phase: String = ""
var choice_time_limit: float = 25.0
var match_over_layer: Control = null
var leave_confirm_layer: Control = null

# =========================================================================
# setup
# =========================================================================

func _ready() -> void:
	var match_setup := _load_match_setup()
	var players: Array = match_setup.get("players", [])
	if not players.is_empty():
		_init_seats_from_players(players)

	phase = str(match_setup.get("phase", ""))
	trump_holder_abs_seat_id = str(match_setup.get("trump_holder_seat_id", ""))
	dealer_view = str(abs_to_local_view.get(str(match_setup.get("dealer_seat_id", "")), ""))
	dealer_draw_cards = (match_setup.get("dealer_draw_cards", []) as Array).duplicate(true)

	is_host = bool(match_setup.get("is_host", false))
	is_spectator = bool(match_setup.get("is_spectator", NetworkManager.is_spectator))

	_build_status_ui()
	_build_countdown_ui()
	_build_action_bar()
	_build_spectator_badge()
	_ensure_nameplates()

	play_button.pressed.connect(_on_play_button_pressed)
	confirm_hidden_trump_button.pressed.connect(_on_confirm_button_pressed)
	open_trump_button.pressed.connect(_on_open_trump_button_pressed)
	arrange_button.pressed.connect(_on_arrange_button_pressed)

	NetworkManager.game_state_snapshot_received.connect(_on_snapshot_received)
	NetworkManager.dealer_draw_updated.connect(_on_dealer_draw_updated)
	NetworkManager.trump_mode_choice_requested.connect(_on_trump_mode_choice_requested)
	NetworkManager.disconnected_from_server.connect(_on_connection_lost)

	play_button.visible = false
	confirm_hidden_trump_button.visible = false
	open_trump_button.visible = false
	trump_suit_icon.visible = false
	turn_timer_widget.visible = false
	turn_timer_widget.modulate.a = 0.0
	_refresh_trump_label()

	if phase == "dealer_draw" or phase == "trump_mode_choice":
		_build_dealer_draw_cards()
	if phase == "trump_mode_choice":
		_show_trump_mode_choice()

	_refresh_hud()

	if not NetworkManager.latest_game_state_snapshot.is_empty():
		_on_snapshot_received(NetworkManager.latest_game_state_snapshot)
	else:
		NetworkManager.request_game_state()

func _load_match_setup() -> Dictionary:
	return NetworkManager.pending_match_setup

func _valid_player_count(count: int) -> int:
	if count == 4 or count == 6 or count == 8:
		return count
	return 4

func _init_seats_from_players(players: Array) -> void:
	current_player_count = _valid_player_count(players.size())
	seat_order = ALL_VIEWS.slice(0, current_player_count)

	local_seat_id = ""
	var players_by_seat := {}
	for p_raw in players:
		var p: Dictionary = p_raw
		players_by_seat[str(p.get("seat_id", ""))] = p
		if bool(p.get("is_local", false)):
			local_seat_id = str(p.get("seat_id", ""))
	if local_seat_id == "":
		local_seat_id = "seat_0"

	_build_view_mapping()

	seat_to_player = {}
	for view_name in seat_order:
		var abs_seat_id := str(local_view_to_abs.get(view_name, ""))
		if players_by_seat.has(abs_seat_id):
			seat_to_player[view_name] = players_by_seat[abs_seat_id]
		else:
			seat_to_player[view_name] = {"name": str(view_name).capitalize(), "is_bot": true, "seat_id": abs_seat_id}

	_ensure_hand_arrays()

func _build_view_mapping() -> void:
	local_view_to_abs.clear()
	abs_to_local_view.clear()
	var n := _valid_player_count(current_player_count)
	var local_index := _seat_index(local_seat_id)
	for offset in range(n):
		var abs_seat_id := "seat_%d" % ((local_index + offset) % n)
		local_view_to_abs[ALL_VIEWS[offset]] = abs_seat_id
		abs_to_local_view[abs_seat_id] = ALL_VIEWS[offset]

func _seat_index(seat_id: String) -> int:
	if seat_id.begins_with("seat_"):
		return int(seat_id.trim_prefix("seat_"))
	return 0

func _ensure_hand_arrays() -> void:
	for view_name in seat_order:
		if not hand_cards.has(view_name):
			hand_cards[view_name] = []

func _hand(view_name: String) -> Array:
	if not hand_cards.has(view_name):
		hand_cards[view_name] = []
	return hand_cards[view_name]

# =========================================================================
# geometry
# =========================================================================

func _view_index(view_name: String) -> int:
	var idx := seat_order.find(view_name)
	return 0 if idx == -1 else idx

func _ring_size() -> Vector2:
	# More players need a wider ring, but the depth is capped by the local hand
	# and the action buttons below it.
	match current_player_count:
		6:
			return Vector2(3.30, 1.68)
		8:
			return Vector2(3.55, 1.72)
		_:
			return Vector2(SEAT_RING_RX, SEAT_RING_RZ)

func _max_opponent_cards() -> int:
	# Fewer backs per seat at a crowded table, so neighbouring stacks do not
	# run into each other.
	return MAX_OPPONENT_CARDS if current_player_count == 4 else 3

func _opponent_spacing() -> float:
	match current_player_count:
		6:
			return 0.19
		8:
			return 0.15
		_:
			return OPPONENT_CARD_SPACING

func _seat_angle(view_name: String) -> float:
	var n := maxi(1, seat_order.size())
	var idx := _view_index(view_name)
	if idx == 0:
		return deg_to_rad(90.0)
	if n <= 2:
		return deg_to_rad(-90.0)
	# Keep a gap clear either side of the local player and spread everyone else
	# over the remaining arc. For 4 players this reproduces the even spacing
	# exactly; for 6 and 8 it lifts the neighbours away from the local hand.
	var gap := maxf(BOTTOM_GAP_DEG, 360.0 / float(n))
	var step := (360.0 - 2.0 * gap) / float(n - 2)
	return deg_to_rad(90.0 - gap - float(idx - 1) * step)

func _seat_anchor_position(view_name: String) -> Vector3:
	var theta := _seat_angle(view_name)
	var ring := _ring_size()
	return SEAT_RING_CENTER + Vector3(cos(theta) * ring.x, 0.0, sin(theta) * ring.y)

func _card_screen_rect(card: Node3D, project: Callable) -> Rect2:
	# The card's face lives in its own XY plane, so transforming the four
	# corners handles flat cards and standing opponent cards alike.
	var half_w := CARD_W * 0.5
	var half_h := CARD_H * 0.5
	var rect := Rect2()
	var first := true
	for corner in [Vector3(-half_w, -half_h, 0), Vector3(half_w, -half_h, 0), Vector3(-half_w, half_h, 0), Vector3(half_w, half_h, 0)]:
		var point: Vector2 = project.call(_to_world(card.transform * corner))
		if first:
			rect = Rect2(point, Vector2.ZERO)
			first = false
		else:
			rect = rect.expand(point)
	return rect

func _seat_screen_rect(view_name: String, project: Callable) -> Rect2:
	var rect := Rect2()
	var first := true
	for card in _hand(view_name):
		if not is_instance_valid(card):
			continue
		var card_rect := _card_screen_rect(card, project)
		if first:
			rect = card_rect
			first = false
		else:
			rect = rect.merge(card_rect)
	if first:
		var fallback: Vector2 = project.call(_to_world(_seat_anchor_position(view_name)))
		rect = Rect2(fallback, Vector2.ZERO)
	return rect

func _nameplate_position(view_name: String, project: Callable, plate_size: Vector2, screen: Vector2) -> Vector2:
	var seat := _seat_screen_rect(view_name, project)
	var side_offset := seat.get_center().x - screen.x * 0.5

	if absf(side_offset) > screen.x * 0.30:
		# Seats stacked up the side of the screen (6- and 8-player tables) have
		# another seat directly below them, so their name goes beside the cards
		# in the empty margin rather than under them.
		var to_right := side_offset > 0.0
		var x := seat.end.x + NAMEPLATE_GAP if to_right else seat.position.x - NAMEPLATE_GAP - plate_size.x
		return Vector2(
			clampf(x, 6.0, maxf(6.0, screen.x - plate_size.x - 6.0)),
			clampf(seat.get_center().y - plate_size.y * 0.5, 6.0, maxf(6.0, screen.y - plate_size.y - 6.0))
		)

	# Everyone else sits just under the cards they belong to, stepping past any
	# other seat's cards that happen to be in the way.
	var pos := Vector2(seat.get_center().x - plate_size.x * 0.5, seat.end.y + NAMEPLATE_GAP)
	for _pass in range(seat_order.size()):
		var moved := false
		for other_raw in seat_order:
			var other := str(other_raw)
			if other == view_name or other == "my":
				continue
			var other_rect: Rect2 = _seat_screen_rect(other, project)
			if other_rect.size == Vector2.ZERO:
				continue
			var hit := Rect2(pos, plate_size).intersection(other_rect)
			if hit.size.x > 4.0 and hit.size.y > 4.0 and other_rect.end.y + NAMEPLATE_GAP > pos.y:
				pos.y = other_rect.end.y + NAMEPLATE_GAP
				moved = true
		if not moved:
			break

	if pos.y + plate_size.y > screen.y - 8.0:
		pos.y = seat.position.y - NAMEPLATE_GAP - plate_size.y
	pos.x = clampf(pos.x, 6.0, maxf(6.0, screen.x - plate_size.x - 6.0))
	pos.y = clampf(pos.y, 6.0, maxf(6.0, screen.y - plate_size.y - 6.0))
	return pos

func _trick_ring_size() -> Vector2:
	# Every player puts a card in the middle, so the ring grows with the table.
	# Depth is the tight one - it has to sit between the far seats and the
	# local hand - so width does most of the work.
	match current_player_count:
		6:
			return Vector2(1.75, 0.76)
		8:
			return Vector2(2.15, 0.60)
		_:
			return Vector2(TRICK_RING_RX, TRICK_RING_RZ)

func _trick_card_scale() -> float:
	# Played cards have to be read, so they stay close to full size. Dropping
	# the tilt below (which cost 40% of a card's width in projection) is what
	# buys the room for that at 6 and 8 players.
	match current_player_count:
		6:
			return 0.92
		8:
			return 0.95
		_:
			return 1.0

func _trick_tilt() -> float:
	# A little scatter looks natural at a 4-player table. With 6 or 8 cards in
	# the middle it just makes them harder to read and wastes the space they
	# need, so they go down square.
	return 14.0 if current_player_count == 4 else 0.0

func _trick_angle(view_name: String) -> float:
	# Unlike the seats, the trick spreads evenly over the whole circle: it does
	# not need a gap kept clear for the local hand, and with 6 or 8 cards to
	# place it cannot afford one. The order around the ring still matches the
	# order around the table, so a card still points back at who played it.
	var n := maxi(1, seat_order.size())
	return deg_to_rad(90.0 - float(_view_index(view_name)) * (360.0 / float(n)))

func _trick_slot_position(view_name: String) -> Vector3:
	var theta := _trick_angle(view_name)
	var ring := _trick_ring_size()
	return TRICK_RING_CENTER + Vector3(cos(theta) * ring.x, 0.0, sin(theta) * ring.y)

func _play_rotation(view_name: String) -> Vector3:
	return Vector3(90.0, 0.0, -_trick_tilt() * cos(_trick_angle(view_name)))

func _my_hand_transform(index: int, count: int) -> Dictionary:
	# The fan is deliberately narrow and shallow: a wider one ran into the
	# captured piles at the sides and the action buttons at the bottom.
	var center := (count - 1) / 2.0
	var spacing := 0.5
	if count > 1:
		spacing = min(0.78, 4.0 / float(count - 1))
	var offset := (index - center) * spacing
	# Short hands fan less, which would leave dead space at the bottom of the
	# screen on 6- and 8-player tables. Nudge them down to compensate.
	var forward := 0.0
	match current_player_count:
		6:
			forward = 0.06
		8:
			forward = 0.12
	return {
		"position": my_seat_anchor.position + Vector3(offset, index * 0.001, forward + abs(index - center) * 0.05),
		"rotation": Vector3(90, 0, (index - center) * 5.0)
	}

func _opponent_hand_transform(view_name: String, index: int, count: int) -> Dictionary:
	# Cards past the cap land on the last slot, so trimming the extras after a
	# deal is invisible (every card back looks the same).
	var slots := mini(count, _max_opponent_cards())
	var slot := mini(index, slots - 1)
	var theta := _seat_angle(view_name)
	var seat_pos := _seat_anchor_position(view_name)
	var center := (slots - 1) / 2.0
	var tangent := Vector3(-sin(theta), 0.0, cos(theta))
	var outward := Vector3(cos(theta), 0.0, sin(theta))
	return {
		"position": seat_pos
			+ tangent * ((float(slot) - center) * _opponent_spacing())
			+ outward * (float(index) * OPPONENT_CARD_DEPTH)
			+ Vector3(0, index * 0.002, 0),
		"rotation": Vector3(0.0, 90.0 - rad_to_deg(theta), (center - float(slot)) * 4.0)
	}

func _is_open_hand(view_name: String) -> bool:
	# The only hand ever drawn face up is the local player's own. A spectator
	# has none, so the bottom seat is treated exactly like the others: a capped
	# stack of card backs.
	return view_name == "my" and not is_spectator

func _visual_count(view_name: String, real_count: int) -> int:
	if _is_open_hand(view_name):
		return real_count
	return mini(real_count, _max_opponent_cards())

func _hand_transform(view_name: String, index: int, count: int) -> Dictionary:
	if view_name == "my":
		return _my_hand_transform(index, count)
	return _opponent_hand_transform(view_name, index, count)

func _pile_marker(team: String) -> Marker3D:
	# The local player's team always uses the near pile.
	if team == my_team:
		return pile_team_a
	return pile_team_b

func _pile_position(team: String, stack_index: int) -> Vector3:
	return _pile_marker(team).position + Vector3(0, PILE_Y_STEP * stack_index, PILE_Z_STEP * stack_index)

func _pile_ten_position(team: String, index: int) -> Vector3:
	# Outward means away from the middle of the table, so the 10s never drift
	# into the trick or the local hand.
	var base := _pile_marker(team).position
	var outward := -1.0 if base.x < 0.0 else 1.0
	return base + Vector3(outward * TEN_OUTWARD, 0.05 + index * 0.002, (float(index) - 1.5) * TEN_SPACING)

func _to_world(local_pos: Vector3) -> Vector3:
	return cards_node.to_global(local_pos)

# =========================================================================
# card helpers
# =========================================================================

func _new_card(card_data: Dictionary, face_up: bool, at_position: Vector3) -> Node3D:
	var card := CARD_SCENE.instantiate()
	cards_node.add_child(card)
	card.position = at_position
	card.rotation_degrees = CARD_FLAT_ROT
	if not card_data.is_empty():
		card.set_card_data(card_data)
	card.set_face_up(face_up)
	card.clickable = false
	return card

func _attach_team_glow(card: Node3D, view_name: String) -> void:
	# A tinted quad a hair behind the card face, slightly larger, so a coloured
	# edge shows all the way round it. Blue means the card came from your side
	# of the table, red from the opposition - which is the only quick way to
	# read a 6- or 8-player trick.
	if card.has_node("TeamGlow"):
		return
	var glow := MeshInstance3D.new()
	glow.name = "TeamGlow"
	var quad := QuadMesh.new()
	quad.size = Vector2(CARD_W * TEAM_GLOW_SCALE, CARD_H * TEAM_GLOW_SCALE)
	glow.mesh = quad

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var tint := _team_color(view_name)
	material.albedo_color = Color(tint.r, tint.g, tint.b, 0.9)
	glow.material_override = material

	# The card's own face sits at local z 0.006, so this stays just behind it
	# and only the overhanging border is visible.
	glow.position = Vector3(0, 0, 0.014)
	card.add_child(glow)

func _tween_card(card: Node3D, target_pos: Vector3, target_rot: Vector3, duration: float, delay: float = 0.0) -> Tween:
	# Created on the card so the tween dies with it instead of writing to a
	# freed object if the table is rebuilt mid-animation.
	var tween := card.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	if delay > 0.0:
		tween.tween_interval(delay)
	# The move must be chained AFTER the interval; only the rotation runs in
	# parallel with it. Marking the move itself parallel would run it
	# alongside the interval and cancel the stagger.
	tween.tween_property(card, "position", target_pos, duration)
	tween.parallel().tween_property(card, "rotation_degrees", target_rot, duration)
	return tween

func _layout_hand(view_name: String, animate: bool = true) -> void:
	var cards: Array = _hand(view_name)
	var count := cards.size()
	var card_scale := Vector3.ONE * (MY_CARD_SCALE if view_name == "my" else 1.0)
	for i in range(count):
		var card: Node3D = cards[i]
		if not is_instance_valid(card):
			continue
		card.scale = card_scale
		var t := _hand_transform(view_name, i, count)
		card.home_position = t["position"]
		card.home_rotation = t["rotation"]
		var target_pos: Vector3 = card.home_position
		if card.selected:
			target_pos += Vector3(0, 0.28, 0.1)
		if animate:
			_tween_card(card, target_pos, card.home_rotation, RELAYOUT_TIME)
		else:
			card.position = target_pos
			card.rotation_degrees = card.home_rotation

func _clear_cards() -> void:
	for child in cards_node.get_children():
		child.queue_free()
	hand_cards.clear()
	seat_card_counts.clear()
	_ensure_hand_arrays()
	trick_entries.clear()
	hidden_trump_node = null
	pile_bundles = {"A": [], "B": []}
	pile_ten_nodes = {"A": [], "B": []}
	dealer_draw_nodes.clear()
	dealer_draw_claimed.clear()
	selected_card = null

# =========================================================================
# snapshot pipeline
# =========================================================================

func _on_snapshot_received(snapshot: Dictionary) -> void:
	var incoming: Dictionary = snapshot.get("game_state", {})
	if incoming.is_empty():
		return
	pending_state = incoming.duplicate(true)
	if not is_rendering:
		_render_loop()

func _render_loop() -> void:
	is_rendering = true
	var gen := render_gen
	while not pending_state.is_empty():
		var target: Dictionary = pending_state
		pending_state = {}
		await _apply_snapshot(target)
		if gen != render_gen or not is_inside_tree():
			is_rendering = false
			return
		state = target
		_sync_result_state(target)
		_check_court_celebration()
		_refresh_hud()
	is_rendering = false
	# _can_interact() is false while a render is in flight, so the pass above
	# always hides the action buttons. Refresh once more now that the table is
	# idle, otherwise buttons like "Reveal Trump" only appear on the next
	# unrelated UI event (which is why one had to tap a card to see it).
	_refresh_hud()

func _apply_snapshot(target: Dictionary) -> void:
	var previous := state
	_sync_meta(target)

	if previous.is_empty():
		if _is_fresh_deal(target):
			_clear_cards()
			await _animate_deal(target)
			await _reveal_my_hand(target)
			_sync_opponent_stacks(target)
			_update_seat_counts(target)
		else:
			_snap_rebuild(target)
		return

	# A new game starts with a fresh first batch: clear the table first.
	if int(target.get("trick_seq", 0)) < int(previous.get("trick_seq", 0)) or _is_new_game(previous, target):
		await _animate_clear_table()
		_clear_cards()
		await _animate_deal(target)
		await _reveal_my_hand(target)
		_sync_opponent_stacks(target)
		_update_seat_counts(target)
		return

	await _animate_trick_capture(previous, target)
	await _animate_hidden_trump_set_aside(previous, target)
	await _animate_plays(target)
	# The trump must fly back to its owner's hand BEFORE the deal step runs.
	# Otherwise _animate_deal sees a card in the hand it has not drawn yet and
	# deals a duplicate out of the deck, which is the stray card that used to
	# come flying from the middle of the table.
	await _animate_trump_reveal(previous, target)
	await _animate_hidden_trump_return(previous, target)
	await _animate_deal(target)
	await _reveal_my_hand(target)

	_sync_opponent_stacks(target)
	_update_seat_counts(target)

	if not _hands_match(target):
		_snap_rebuild(target)

func _sync_meta(target: Dictionary) -> void:
	var snap_count := int(target.get("player_count", current_player_count))
	if snap_count != current_player_count and (snap_count == 4 or snap_count == 6 or snap_count == 8):
		current_player_count = snap_count
		seat_order = ALL_VIEWS.slice(0, snap_count)
		_build_view_mapping()
		_ensure_hand_arrays()
		_ensure_nameplates()

	# The server tells every client which absolute seat it is sitting in.
	# Trust that over anything handed in from the lobby, so a stale or wrong
	# handoff can never rotate this client's view of the table.
	var my_info: Dictionary = target.get("seat_info", {}).get("my", {})
	var my_seat_id := str(my_info.get("seat_id", ""))
	if my_seat_id != "" and my_seat_id != local_seat_id:
		local_seat_id = my_seat_id
		_build_view_mapping()
		_ensure_nameplates()

	var info: Dictionary = target.get("seat_info", {})
	for view_key in info.keys():
		var view_name := str(view_key)
		var entry: Dictionary = info[view_key]
		var existing: Dictionary = seat_to_player.get(view_name, {})
		existing["name"] = str(entry.get("name", existing.get("name", "Player")))
		existing["is_bot"] = bool(entry.get("is_bot", false))
		existing["is_connected"] = bool(entry.get("is_connected", true))
		existing["seat_id"] = str(entry.get("seat_id", existing.get("seat_id", "")))
		existing["team"] = str(entry.get("team", existing.get("team", "A")))
		seat_to_player[view_name] = existing
	if info.has("my"):
		my_team = str((info["my"] as Dictionary).get("team", "A"))

	phase = str(target.get("phase", phase))
	trump_mode = str(target.get("trump_mode", trump_mode))
	trump_active = bool(target.get("trump_active", false))
	trump_suit = str(target.get("trump_suit", ""))
	lead_suit = str(target.get("current_lead_suit", ""))
	must_play_trump = bool(target.get("must_play_trump", false))
	trump_holder_abs_seat_id = str(target.get("trump_holder_seat_id", trump_holder_abs_seat_id))
	trump_holder_view = str(target.get("hidden_trump_holder_seat", trump_holder_view))
	dealer_view = str(target.get("dealer_seat", dealer_view))

	# The server is the authority on whether this client holds a seat, so a
	# snapshot can promote a client to watching but never the other way round.
	if bool(target.get("is_spectator", false)):
		is_spectator = true

	var turn_index := int(target.get("current_turn_index", -1))
	my_turn = (turn_index == 0) and not is_spectator
	table_busy = bool(target.get("trick_is_resolving", false)) or bool(target.get("revealing_trump", false)) or phase == "dealing"

func _is_new_game(previous: Dictionary, target: Dictionary) -> bool:
	var prev_phase := str(previous.get("phase", ""))
	var new_phase := str(target.get("phase", ""))
	if new_phase != "trump_mode_choice":
		return false
	return prev_phase == "game_result" or prev_phase == "playing" or prev_phase == "match_result"

func _first_batch_size() -> int:
	match current_player_count:
		6:
			return 4
		8:
			return 3
		_:
			return 5

func _is_fresh_deal(target: Dictionary) -> bool:
	if str(target.get("phase", "")) != "trump_mode_choice":
		return false
	if int(target.get("trick_seq", 0)) != 0:
		return false
	var hands: Dictionary = target.get("hands", {})
	var expected := _first_batch_size()
	for view_name in seat_order:
		if (hands.get(view_name, []) as Array).size() != expected:
			return false
	return true

func _hands_match(target: Dictionary) -> bool:
	var hands: Dictionary = target.get("hands", {})
	for view_name in seat_order:
		var real: int = (hands.get(view_name, []) as Array).size()
		if _visual_count(view_name, real) != _hand(view_name).size():
			return false
	return (target.get("trick_cards", []) as Array).size() == trick_entries.size()

func _update_seat_counts(target: Dictionary) -> void:
	var hands: Dictionary = target.get("hands", {})
	for view_name in seat_order:
		seat_card_counts[view_name] = (hands.get(view_name, []) as Array).size()

func _sync_opponent_stacks(target: Dictionary) -> void:
	# Opponent stacks are capped, so after a deal (extra cards) or a play
	# (one card short) the stack is quietly brought back to size. Every card
	# back is identical, so this is invisible.
	var hands: Dictionary = target.get("hands", {})
	for view_name in seat_order:
		if _is_open_hand(view_name):
			continue
		var real: int = (hands.get(view_name, []) as Array).size()
		var want := _visual_count(view_name, real)
		var cards: Array = _hand(view_name)
		if cards.size() == want:
			continue

		while cards.size() > want:
			var extra: Node3D = cards.pop_back()
			if is_instance_valid(extra):
				extra.queue_free()
		while cards.size() < want:
			var t := _hand_transform(view_name, cards.size(), want)
			var card := _new_card({}, false, t["position"])
			card.rotation_degrees = t["rotation"]
			cards.append(card)

		hand_cards[view_name] = cards
		_layout_hand(view_name, false)

# =========================================================================
# animations
# =========================================================================

func _animate_deal(target: Dictionary) -> void:
	var hands: Dictionary = target.get("hands", {})
	var deal_order: Array = target.get("deal_order", [])
	if deal_order.is_empty():
		deal_order = seat_order

	var deck_pos := deck_point.position
	var new_my_cards: Array = []
	var dealt_nodes: Array = []

	for view_raw in deal_order:
		var view_name := str(view_raw)
		if not seat_order.has(view_name):
			continue
		var target_hand: Array = hands.get(view_name, [])
		var cards: Array = _hand(view_name)

		if _is_open_hand(view_name):
			# Keep the player's current order (sorting must survive) and
			# append only genuinely new cards.
			var present := {}
			for card in cards:
				present[str(card.card_id)] = true
			# The set-aside trump lives in its own slot, not in the hand, so it
			# must never be dealt a second time out of the deck.
			if hidden_trump_node != null and is_instance_valid(hidden_trump_node):
				present[str(hidden_trump_node.card_id)] = true
			for card_state_raw in target_hand:
				var card_state: Dictionary = card_state_raw
				var cid := str(card_state.get("card_id", ""))
				if present.has(cid):
					continue
				var card := _new_card(card_state, false, deck_pos)
				card.clickable = true
				card.card_clicked.connect(_on_card_clicked)
				cards.append(card)
				new_my_cards.append(card)
				dealt_nodes.append(card)
		else:
			# Deal the number of cards the server actually handed out, even if
			# only a few of them stay on the table afterwards.
			var previous_real := int(seat_card_counts.get(view_name, cards.size()))
			var dealt := target_hand.size() - previous_real
			for _i in range(dealt):
				var card := _new_card({}, false, deck_pos)
				cards.append(card)
				dealt_nodes.append(card)

		hand_cards[view_name] = cards

	if dealt_nodes.is_empty():
		return

	# Lay out every hand, then animate only the freshly dealt cards from the
	# deck, one after another, so the deal reads as a real deal.
	for view_name in seat_order:
		var cards: Array = _hand(view_name)
		var count := cards.size()
		for i in range(count):
			var card: Node3D = cards[i]
			var t := _hand_transform(view_name, i, count)
			card.home_position = t["position"]
			card.home_rotation = t["rotation"]
			if not dealt_nodes.has(card):
				_tween_card(card, card.home_position, card.home_rotation, RELAYOUT_TIME)

	_set_phase_message("Dealing...")
	var delay := 0.0
	var last_tween: Tween = null
	for card in dealt_nodes:
		last_tween = _tween_card(card, card.home_position, card.home_rotation, DEAL_TIME, delay)
		delay += DEAL_STAGGER

	if last_tween != null:
		await last_tween.finished
	if not is_inside_tree():
		return

	# Cards stay face down here. _reveal_my_hand() turns them over once the
	# trump has been settled, so the closed trump is chosen blind.
	if new_my_cards.is_empty():
		return
	_clear_phase_message()

func _in_trump_setup() -> bool:
	return phase == "trump_mode_choice" or phase == "closed_trump_card_choice"

func _reveal_my_hand(target: Dictionary) -> void:
	# The server sends placeholder faces during the trump setup, so refresh
	# the card data first, then turn over anything still face down.
	if _in_trump_setup():
		return
	# A spectator's bottom seat is somebody else's hand, and the server sends it
	# redacted. Turning it over would show four placeholder 2s.
	if is_spectator:
		return

	var by_id := {}
	for card_state_raw in (target.get("hands", {}) as Dictionary).get("my", []):
		var card_state: Dictionary = card_state_raw
		by_id[str(card_state.get("card_id", ""))] = card_state

	var to_flip: Array = []
	for card in _hand("my"):
		if not is_instance_valid(card):
			continue
		var card_state: Dictionary = by_id.get(str(card.card_id), {})
		if card_state.is_empty():
			continue
		if str(card.suit) != str(card_state.get("suit", "")) or str(card.rank) != str(card_state.get("rank", "")):
			card.set_card_data(card_state)
		if not card.is_face_up:
			to_flip.append(card)

	if to_flip.is_empty():
		return

	for card in to_flip:
		card.flip_card()
		await get_tree().create_timer(FLIP_STAGGER).timeout
		if not is_inside_tree():
			return
	await get_tree().create_timer(0.26).timeout
	if not is_inside_tree():
		return

	if my_hand_sorted:
		_sort_my_hand()
	_clear_phase_message()

func _animate_plays(target: Dictionary) -> void:
	# Compare against what is actually on the table, not against the previous
	# snapshot: snapshots can be skipped while an animation is running, and a
	# new trick can be smaller than the one it replaced.
	var new_trick: Array = target.get("trick_cards", [])
	if new_trick.is_empty():
		return

	var rendered_ids := {}
	for entry in trick_entries:
		rendered_ids[str(entry["card_id"])] = true

	for entry_raw in new_trick:
		var entry: Dictionary = entry_raw
		var card_id := str(entry.get("card_id", ""))
		if rendered_ids.has(card_id):
			continue
		await _animate_single_play(entry)
		if not is_inside_tree():
			return

func _animate_single_play(entry: Dictionary) -> void:
	var view_name := str(entry.get("seat", "my"))
	var card_id := str(entry.get("card_id", ""))
	var cards: Array = _hand(view_name)
	var card: Node3D = null

	if view_name == "my":
		for c in cards:
			if str(c.card_id) == card_id:
				card = c
				break
	elif not cards.is_empty():
		# Opponent hands are anonymous face-down cards: take one and give it
		# the real identity the server just revealed.
		card = cards[cards.size() - 1]
		card.set_card_data(entry)

	if card == null:
		card = _new_card(entry, false, _seat_anchor_position(view_name))
	else:
		cards.erase(card)
		hand_cards[view_name] = cards

	if selected_card == card:
		selected_card = null
	card.clickable = false
	card.selected = false
	card.played = true
	# Only the local hand is drawn oversized; played cards shrink at a
	# crowded table so the trick stays readable.
	card.scale = Vector3.ONE * _trick_card_scale()
	_attach_team_glow(card, view_name)

	var tween := _tween_card(card, _trick_slot_position(view_name), _play_rotation(view_name), PLAY_TIME)
	trick_entries.append({"seat": view_name, "card_id": card_id, "node": card})
	_layout_hand(view_name)

	await tween.finished
	if not is_inside_tree():
		return
	if is_instance_valid(card) and not card.is_face_up:
		card.flip_card()

func _animate_trick_capture(previous: Dictionary, target: Dictionary) -> void:
	var last_trick: Dictionary = target.get("last_trick", {})
	if last_trick.is_empty():
		return
	var seq := int(last_trick.get("seq", 0))
	if seq <= int((previous.get("last_trick", {}) as Dictionary).get("seq", 0)):
		return

	var team := str(last_trick.get("team", "A"))
	var trick_cards: Array = last_trick.get("cards", [])

	# Make sure every card of the trick is on the table before it flies away
	# (covers the case where a snapshot was skipped while animating).
	var rendered := {}
	for e in trick_entries:
		rendered[str(e["card_id"])] = e["node"]
	var moving: Array = []
	for entry_raw in trick_cards:
		var entry: Dictionary = entry_raw
		var cid := str(entry.get("card_id", ""))
		if rendered.has(cid):
			moving.append(rendered[cid])
			rendered.erase(cid)
		else:
			var view_name := str(entry.get("seat", "my"))
			var node := _new_card(entry, true, _trick_slot_position(view_name))
			node.rotation_degrees = _play_rotation(view_name)
			node.scale = Vector3.ONE * _trick_card_scale()
			_attach_team_glow(node, view_name)
			node.played = true
			moving.append(node)
	for leftover in rendered.values():
		moving.append(leftover)

	var winner_name := _display_name(str(last_trick.get("winner_seat", "")))
	_set_phase_message("%s wins the trick" % winner_name)
	await get_tree().create_timer(CAPTURE_HOLD).timeout
	if not is_inside_tree():
		return

	var stack_index := int(last_trick.get("pile_index", pile_bundles.get(team, []).size()))
	var pile_pos := _pile_position(team, stack_index)
	var tween: Tween = null
	for card in moving:
		if is_instance_valid(card):
			tween = _tween_card(card, pile_pos, CARD_FLAT_ROT, CAPTURE_TIME)

	trick_entries.clear()

	if tween != null:
		await tween.finished
	if not is_inside_tree():
		return

	for card in moving:
		if is_instance_valid(card):
			card.queue_free()

	_add_pile_bundle(team, stack_index, last_trick.get("tens", []))
	_clear_phase_message()

func _add_pile_bundle(team: String, stack_index: int, tens: Array) -> void:
	var pile_pos := _pile_position(team, stack_index)
	var bundle := _new_card({}, false, pile_pos)
	bundle.played = true
	(pile_bundles[team] as Array).append(bundle)

	if tens.is_empty():
		return

	# Captured 10s stay face up next to the pile so both teams can count them.
	var existing: Array = pile_ten_nodes[team]
	for ten_raw in tens:
		var ten: Dictionary = ten_raw
		var index := existing.size()
		var ten_card := _new_card(ten, true, pile_pos)
		ten_card.played = true
		existing.append(ten_card)
		_tween_card(ten_card, _pile_ten_position(team, index), CARD_FLAT_ROT, 0.28, index * 0.06)
	pile_ten_nodes[team] = existing

func _animate_hidden_trump_set_aside(previous: Dictionary, target: Dictionary) -> void:
	var old_ht: Dictionary = previous.get("hidden_trump", {})
	var new_ht: Dictionary = target.get("hidden_trump", {})
	if not bool(new_ht.get("is_set_aside", false)):
		return
	if bool(old_ht.get("is_set_aside", false)):
		return
	if hidden_trump_node != null and is_instance_valid(hidden_trump_node):
		return

	var holder_view := str(new_ht.get("holder_seat", target.get("hidden_trump_holder_seat", "")))
	var cards: Array = _hand(holder_view)
	var card: Node3D = null

	if holder_view == "my":
		# Find which of my cards is no longer in my hand.
		var target_ids := {}
		for card_state_raw in (target.get("hands", {}) as Dictionary).get("my", []):
			target_ids[str((card_state_raw as Dictionary).get("card_id", ""))] = true
		for c in cards:
			if not target_ids.has(str(c.card_id)):
				card = c
				break
	elif not cards.is_empty():
		card = cards[cards.size() - 1]

	if card == null:
		card = _new_card({}, false, _seat_anchor_position(holder_view))
	else:
		cards.erase(card)
		hand_cards[holder_view] = cards

	if selected_card == card:
		selected_card = null
	card.clickable = false
	card.selected = false
	card.set_face_up(false)
	card.scale = Vector3.ONE
	hidden_trump_node = card
	# _animate_deal works out how many cards a seat was dealt by comparing the
	# server's hand size against this count, so it has to follow the card out
	# of the hand. Otherwise the seat looks one card short and gets an extra
	# one dealt from the deck.
	if holder_view != "my":
		seat_card_counts[holder_view] = maxi(0, int(seat_card_counts.get(holder_view, 0)) - 1)

	var tween := _tween_card(card, hidden_trump_slot.position, CARD_FLAT_ROT, TRUMP_MOVE_TIME)
	_layout_hand(holder_view)
	await tween.finished

func _animate_trump_reveal(previous: Dictionary, target: Dictionary) -> void:
	var old_ht: Dictionary = previous.get("hidden_trump", {})
	var new_ht: Dictionary = target.get("hidden_trump", {})
	if not bool(new_ht.get("is_revealed", false)):
		return
	if bool(old_ht.get("is_revealed", false)):
		return
	if hidden_trump_node == null or not is_instance_valid(hidden_trump_node):
		return

	# The server only sends the real suit/rank once the card is revealed.
	hidden_trump_node.set_card_data(new_ht)
	hidden_trump_node.flip_card()
	_set_phase_message("Trump revealed: %s" % str(new_ht.get("suit", "")).capitalize())
	_refresh_trump_icon()
	_animate_trump_icon_in()
	await get_tree().create_timer(0.6).timeout

func _animate_hidden_trump_return(previous: Dictionary, target: Dictionary) -> void:
	var old_ht: Dictionary = previous.get("hidden_trump", {})
	var new_ht: Dictionary = target.get("hidden_trump", {})
	if not bool(new_ht.get("has_returned_to_hand", false)):
		return
	if bool(old_ht.get("has_returned_to_hand", false)):
		return
	if hidden_trump_node == null or not is_instance_valid(hidden_trump_node):
		return

	var holder_view := str(new_ht.get("holder_seat", target.get("hidden_trump_holder_seat", "")))
	var card := hidden_trump_node
	hidden_trump_node = null

	if holder_view == "my":
		card.set_face_up(true)
		card.clickable = true
		if not card.card_clicked.is_connected(_on_card_clicked):
			card.card_clicked.connect(_on_card_clicked)
	else:
		card.set_face_up(false)

	var cards: Array = _hand(holder_view)
	cards.append(card)
	hand_cards[holder_view] = cards
	# The seat is one card richer again; without this _animate_deal sees the
	# server's larger hand as a fresh deal and flies a duplicate in from the
	# deck in the middle of the table.
	if holder_view != "my":
		seat_card_counts[holder_view] = int(seat_card_counts.get(holder_view, 0)) + 1

	var count := cards.size()
	var t := _hand_transform(holder_view, count - 1, count)
	card.home_position = t["position"]
	card.home_rotation = t["rotation"]
	var tween := _tween_card(card, card.home_position, card.home_rotation, TRUMP_MOVE_TIME)
	_layout_hand(holder_view)
	_clear_phase_message()
	await tween.finished
	if is_inside_tree() and my_hand_sorted and holder_view == "my":
		_sort_my_hand()

func _animate_clear_table() -> void:
	var nodes: Array = []
	for view_name in seat_order:
		for card in _hand(view_name):
			if is_instance_valid(card):
				nodes.append(card)
	for entry in trick_entries:
		if is_instance_valid(entry["node"]):
			nodes.append(entry["node"])
	if nodes.is_empty():
		return
	var tween: Tween = null
	for card in nodes:
		tween = _tween_card(card, deck_point.position, CARD_FLAT_ROT, 0.3)
	if tween != null:
		await tween.finished

func _snap_rebuild(target: Dictionary) -> void:
	# Reconnect / desync path: draw the exact server state with no animation.
	# Runs at the end of _apply_snapshot, so no other animation is in flight.
	_clear_cards()

	var hands: Dictionary = target.get("hands", {})
	for view_name in seat_order:
		var cards: Array = []
		var source: Array = hands.get(view_name, [])
		var draw_count := _visual_count(view_name, source.size())
		for i in range(draw_count):
			var card_state: Dictionary = source[i]
			var face_up: bool = _is_open_hand(view_name) and not _in_trump_setup()
			var card := _new_card(card_state, face_up, Vector3.ZERO)
			if _is_open_hand(view_name):
				card.clickable = true
				card.card_clicked.connect(_on_card_clicked)
			cards.append(card)
		hand_cards[view_name] = cards
		_layout_hand(view_name, false)
	_update_seat_counts(target)

	for entry_raw in target.get("trick_cards", []):
		var entry: Dictionary = entry_raw
		var view_name := str(entry.get("seat", "my"))
		var card := _new_card(entry, true, _trick_slot_position(view_name))
		card.rotation_degrees = _play_rotation(view_name)
		card.scale = Vector3.ONE * _trick_card_scale()
		_attach_team_glow(card, view_name)
		card.played = true
		trick_entries.append({"seat": view_name, "card_id": str(entry.get("card_id", "")), "node": card})

	var ht: Dictionary = target.get("hidden_trump", {})
	if bool(ht.get("is_set_aside", false)):
		hidden_trump_node = _new_card(ht, bool(ht.get("is_revealed", false)), hidden_trump_slot.position)

	var captured_tens: Dictionary = target.get("captured_ten_cards", {"A": [], "B": []})
	for team in ["A", "B"]:
		var trick_count := int(target.get("team_a_trick_count", 0)) if team == "A" else int(target.get("team_b_trick_count", 0))
		for i in range(trick_count):
			var bundle := _new_card({}, false, _pile_position(team, i))
			bundle.played = true
			(pile_bundles[team] as Array).append(bundle)
		var tens: Array = captured_tens.get(team, [])
		for i in range(tens.size()):
			var ten_card := _new_card(tens[i], true, _pile_ten_position(team, i))
			ten_card.played = true
			(pile_ten_nodes[team] as Array).append(ten_card)

# =========================================================================
# input
# =========================================================================

func _can_interact() -> bool:
	return not table_busy and not is_rendering and not is_spectator

func _on_card_clicked(card: Node3D) -> void:
	if not _can_interact():
		return

	if phase == "closed_trump_card_choice":
		if not _is_local_trump_holder():
			return
	elif phase == "playing":
		if not my_turn:
			return
		if not _is_legal_play(card):
			if _owes_trump():
				_set_phase_message("You opened the trump - you must play a %s" % trump_suit.capitalize())
			else:
				_set_phase_message("You must follow %s" % lead_suit.capitalize())
			return
	else:
		return

	if selected_card == card:
		card.set_selected(false)
		selected_card = null
		_refresh_buttons()
		return

	if selected_card != null and is_instance_valid(selected_card):
		selected_card.set_selected(false)
	selected_card = card
	card.set_selected(true)
	_refresh_buttons()

func _owes_trump() -> bool:
	# Set by the server on the player who opened the hidden trump: they must
	# play a trump this turn if they hold one.
	return must_play_trump and trump_active and trump_suit != "" and _my_hand_has_suit(trump_suit)

func _is_legal_play(card: Node3D) -> bool:
	if _owes_trump():
		return str(card.suit).to_lower() == trump_suit.to_lower()
	if lead_suit == "":
		return true
	if _my_hand_has_suit(lead_suit):
		return str(card.suit).to_lower() == lead_suit.to_lower()
	return true

func _trump_holder_view() -> String:
	# Prefer the view the server resolved for this client; fall back to the
	# local mapping only before the first snapshot arrives.
	if trump_holder_view != "":
		return trump_holder_view
	return str(abs_to_local_view.get(trump_holder_abs_seat_id, ""))

func _is_local_trump_holder() -> bool:
	return _trump_holder_view() == "my"

func _on_play_button_pressed() -> void:
	if selected_card == null or not _can_interact() or not my_turn:
		return
	NetworkManager.send_game_action({"type": "play_card", "card_id": selected_card.card_id})
	play_button.disabled = true

func _on_confirm_button_pressed() -> void:
	if phase == "trump_mode_choice":
		NetworkManager.choose_trump_mode("hidden")
		confirm_hidden_trump_button.disabled = true
		open_trump_button.disabled = true
		return
	if phase == "closed_trump_card_choice" and selected_card != null:
		NetworkManager.send_game_action({"type": "confirm_hidden_trump", "card_id": selected_card.card_id})
		confirm_hidden_trump_button.disabled = true

func _on_open_trump_button_pressed() -> void:
	if phase == "trump_mode_choice":
		NetworkManager.choose_trump_mode("open")
		confirm_hidden_trump_button.disabled = true
		open_trump_button.disabled = true
		return
	if phase == "playing":
		NetworkManager.send_game_action({"type": "open_trump"})
		open_trump_button.disabled = true

func _on_arrange_button_pressed() -> void:
	my_hand_sorted = true
	_sort_my_hand()

func _sort_my_hand() -> void:
	var cards: Array = _hand("my")
	if cards.is_empty():
		return
	var suit_order := ["spades", "hearts", "clubs", "diamonds"]
	if trump_active and trump_suit != "":
		suit_order.erase(trump_suit.to_lower())
		suit_order.push_front(trump_suit.to_lower())
	var rank_order := ["ace", "king", "queen", "jack", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
	cards.sort_custom(func(a, b):
		var sa := suit_order.find(str(a.suit).to_lower())
		var sb := suit_order.find(str(b.suit).to_lower())
		if sa != sb:
			return sa < sb
		return rank_order.find(str(a.rank).to_lower()) < rank_order.find(str(b.rank).to_lower())
	)
	hand_cards["my"] = cards
	_layout_hand("my")

# =========================================================================
# dealer draw
# =========================================================================

func _build_dealer_draw_cards() -> void:
	_clear_cards()
	var total := dealer_draw_cards.size()
	var spacing := 0.6 if total <= 6 else 0.5

	for card_state_raw in dealer_draw_cards:
		var card_state: Dictionary = card_state_raw
		var draw_index := int(card_state.get("draw_index", 0))
		var pos := TRICK_RING_CENTER + Vector3((float(draw_index) - (float(total) - 1.0) / 2.0) * spacing, 0, 0)
		var card := _new_card({
			"card_id": "dealer_draw_%d" % draw_index,
			"suit": str(card_state.get("suit", "")),
			"rank": str(card_state.get("rank", ""))
		}, false, pos)
		card.clickable = not bool(card_state.get("is_claimed", false)) and not is_spectator
		if card.clickable:
			card.card_clicked.connect(func(_c): _on_dealer_draw_clicked(draw_index))
		dealer_draw_nodes[draw_index] = card

	for card_state_raw in dealer_draw_cards:
		var card_state: Dictionary = card_state_raw
		if bool(card_state.get("is_claimed", false)):
			_place_claimed_draw_card(card_state, false)

	_set_phase_message("Picking a dealer..." if is_spectator else "Pick a card to decide the dealer")

func _on_dealer_draw_clicked(draw_index: int) -> void:
	if phase != "dealer_draw" or dealer_draw_selected != -1 or is_spectator:
		return
	dealer_draw_selected = draw_index
	NetworkManager.claim_dealer_draw_card(draw_index)
	for other in dealer_draw_nodes.values():
		if is_instance_valid(other):
			other.clickable = false
	_refresh_phase_message()

func _place_claimed_draw_card(card_state: Dictionary, animate: bool) -> void:
	var draw_index := int(card_state.get("draw_index", 0))
	if dealer_draw_claimed.get(draw_index, false):
		return
	if not dealer_draw_nodes.has(draw_index):
		return
	var card: Node3D = dealer_draw_nodes[draw_index]
	if not is_instance_valid(card):
		return

	card.clickable = false
	card.set_face_up(true)
	var view_name := str(abs_to_local_view.get(str(card_state.get("claimed_by_seat_id", "")), "my"))
	var target_pos := _trick_slot_position(view_name)
	if animate:
		_tween_card(card, target_pos, CARD_FLAT_ROT, 0.35)
	else:
		card.position = target_pos
		card.rotation_degrees = CARD_FLAT_ROT
	dealer_draw_claimed[draw_index] = true

func _on_dealer_draw_updated(match_data: Dictionary) -> void:
	phase = str(match_data.get("phase", phase))
	choice_time_limit = maxf(1.0, float(match_data.get("choice_time_limit", choice_time_limit)))
	_arm_choice_deadline(phase)
	dealer_draw_cards = (match_data.get("dealer_draw_cards", []) as Array).duplicate(true)
	trump_holder_abs_seat_id = str(match_data.get("trump_holder_seat_id", trump_holder_abs_seat_id))
	var dealer_abs := str(match_data.get("dealer_seat_id", ""))
	if dealer_abs != "":
		dealer_view = str(abs_to_local_view.get(dealer_abs, dealer_view))

	if dealer_draw_nodes.is_empty():
		_build_dealer_draw_cards()
	else:
		for card_state_raw in dealer_draw_cards:
			var card_state: Dictionary = card_state_raw
			if bool(card_state.get("is_claimed", false)):
				_place_claimed_draw_card(card_state, true)
	_refresh_phase_message()

func _on_trump_mode_choice_requested(match_data: Dictionary) -> void:
	_on_dealer_draw_updated(match_data)
	phase = "trump_mode_choice"
	_arm_choice_deadline(phase)
	_show_trump_mode_choice()

func _hide_trump_mode_choice() -> void:
	if trump_mode_layer != null and is_instance_valid(trump_mode_layer):
		trump_mode_layer.queue_free()
	trump_mode_layer = null
	trump_mode_countdown = null

func _trump_option(title: String, blurb: String, accent: bool, on_pressed: Callable) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size = Vector2(280, 0)

	var button := Button.new()
	button.name = title.replace(" ", "") + "Button"
	button.text = title
	button.custom_minimum_size = Vector2(280, 54)
	if accent:
		button.theme_type_variation = &"AccentButton"
	button.pressed.connect(on_pressed)
	column.add_child(button)

	var note := _hud_label(blurb, 14, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	note.custom_minimum_size = Vector2(280, 0)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	return column

func _show_trump_mode_choice() -> void:
	# The bottom row is for playing cards; a decision this important gets the
	# middle of the table, with the rules of each option spelled out.
	confirm_hidden_trump_button.visible = false
	open_trump_button.visible = false
	play_button.visible = false

	if trump_mode_layer != null and is_instance_valid(trump_mode_layer):
		return

	var mine := _is_local_trump_holder()

	var layer := Control.new()
	layer.name = "TrumpModeChoice"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(layer)
	trump_mode_layer = layer

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.12, 0.09, 0.98)
	style.border_color = Color(0.24, 0.35, 0.29)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.content_margin_left = 34
	style.content_margin_right = 34
	style.content_margin_top = 26
	style.content_margin_bottom = 26
	card.add_theme_stylebox_override("panel", style)
	center.add_child(card)

	var box := VBoxContainer.new()
	box.name = "TrumpModeBox"
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)

	if mine:
		box.add_child(_hud_label("CHOOSE THE TRUMP", 28, COL_GOLD, HORIZONTAL_ALIGNMENT_CENTER))
		box.add_child(_hud_label("You were served first, so the trump is yours to set.", 15, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 12)
		box.add_child(spacer)

		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 18)
		box.add_child(row)

		row.add_child(_trump_option(
			"Closed Trump",
			"Set one card from your first batch aside, face down. Nobody sees it, not even you. Anyone who cannot follow suit may reveal it later.",
			true, func(): _choose_trump_mode("hidden")))
		row.add_child(_trump_option(
			"Open Trump",
			"No card is set aside. The first time a player cannot follow suit, whatever suit they play becomes the trump.",
			false, func(): _choose_trump_mode("open")))
	else:
		box.add_child(_hud_label("CHOOSING THE TRUMP", 24, COL_GOLD, HORIZONTAL_ALIGNMENT_CENTER))
		var waiting := _hud_label("%s was served first and is setting the trump." % _display_name(_trump_holder_view()), 17, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		waiting.custom_minimum_size = Vector2(420, 0)
		waiting.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(waiting)

	trump_mode_countdown = _hud_label("", 16, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(trump_mode_countdown)

func _choose_trump_mode(mode: String) -> void:
	NetworkManager.choose_trump_mode(mode)
	if trump_mode_layer != null and is_instance_valid(trump_mode_layer):
		for button in trump_mode_layer.find_children("*", "Button", true, false):
			(button as Button).disabled = true

# =========================================================================
# HUD
# =========================================================================

func _hud_label(text: String, font_size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _score_cell(key: String, text: String, font_size: int, color: Color) -> Label:
	var label := _hud_label(text, font_size, color, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(52, 0)
	hud_values[key] = label
	return label

func _build_status_ui() -> void:
	# One readable scoreboard instead of a wall of text: a header, a row per
	# team with its own columns, then who deals and who is on turn.
	score_panel = PanelContainer.new()
	score_panel.name = "ScorePanel"
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.04, 0.09, 0.06, 0.88)
	panel_style.border_color = Color(0.18, 0.29, 0.23, 0.9)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(14)
	panel_style.content_margin_left = 16
	panel_style.content_margin_right = 16
	panel_style.content_margin_top = 12
	panel_style.content_margin_bottom = 12
	score_panel.add_theme_stylebox_override("panel", panel_style)
	score_panel.position = Vector2(14, 12)
	score_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(score_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_panel.add_child(column)

	var target_label := _hud_label("RACE TO 15", 12, COL_MUTED)
	hud_values["target"] = target_label
	column.add_child(target_label)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 2)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(grid)

	var name_header := _hud_label("", 11, COL_MUTED)
	name_header.custom_minimum_size = Vector2(96, 0)
	grid.add_child(name_header)
	grid.add_child(_hud_label("SCORE", 11, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	grid.add_child(_hud_label("10s", 11, COL_GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	grid.add_child(_hud_label("TRICKS", 11, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	var you_name := _hud_label("YOUR TEAM", 14, COL_YOU)
	you_name.custom_minimum_size = Vector2(96, 0)
	team_row_labels["you"] = you_name
	grid.add_child(you_name)
	grid.add_child(_score_cell("you_score", "0", 22, COL_TEXT))
	grid.add_child(_score_cell("you_tens", "0 / 4", 16, COL_GOLD))
	grid.add_child(_score_cell("you_tricks", "0", 16, COL_MUTED))

	var them_name := _hud_label("OPPONENTS", 14, COL_THEM)
	them_name.custom_minimum_size = Vector2(96, 0)
	team_row_labels["them"] = them_name
	grid.add_child(them_name)
	grid.add_child(_score_cell("them_score", "0", 22, COL_TEXT))
	grid.add_child(_score_cell("them_tens", "0 / 4", 16, COL_GOLD))
	grid.add_child(_score_cell("them_tricks", "0", 16, COL_MUTED))

	var rule := HSeparator.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	var footer := GridContainer.new()
	footer.columns = 2
	footer.add_theme_constant_override("h_separation", 10)
	footer.add_theme_constant_override("v_separation", 1)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(footer)

	var dealer_caption := _hud_label("Dealer", 12, COL_MUTED)
	dealer_caption.custom_minimum_size = Vector2(56, 0)
	footer.add_child(dealer_caption)
	var dealer_value := _hud_label("-", 13, COL_TEXT)
	hud_values["dealer"] = dealer_value
	footer.add_child(dealer_value)

	var turn_caption := _hud_label("Turn", 12, COL_MUTED)
	turn_caption.custom_minimum_size = Vector2(56, 0)
	footer.add_child(turn_caption)
	var turn_value := _hud_label("-", 13, COL_TEXT)
	hud_values["turn"] = turn_value
	footer.add_child(turn_value)

	# Trump gets its own chip in the bottom-right corner: big enough to read at
	# a glance, next to the hand and the action buttons where the player is
	# already looking, and out of the far corner it used to hide in.
	trump_panel = PanelContainer.new()
	trump_panel.name = "TrumpChip"
	var trump_style := StyleBoxFlat.new()
	trump_style.bg_color = Color(0.04, 0.09, 0.06, 0.88)
	trump_style.border_color = Color(0.18, 0.29, 0.23, 0.9)
	trump_style.set_border_width_all(1)
	trump_style.set_corner_radius_all(14)
	trump_style.content_margin_left = 14
	trump_style.content_margin_right = 16
	trump_style.content_margin_top = 8
	trump_style.content_margin_bottom = 8
	trump_panel.add_theme_stylebox_override("panel", trump_style)
	trump_panel.anchor_left = 1.0
	trump_panel.anchor_top = 1.0
	trump_panel.anchor_right = 1.0
	trump_panel.anchor_bottom = 1.0
	trump_panel.offset_left = -212.0
	trump_panel.offset_top = -86.0
	trump_panel.offset_right = -14.0
	trump_panel.offset_bottom = -22.0
	trump_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(trump_panel)

	var trump_row := HBoxContainer.new()
	trump_row.add_theme_constant_override("separation", 10)
	trump_row.alignment = BoxContainer.ALIGNMENT_CENTER
	trump_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trump_panel.add_child(trump_row)

	# The icon and label live in the scene; move them into the chip so their
	# layout is container-driven instead of anchored to the screen corner.
	trump_suit_icon.get_parent().remove_child(trump_suit_icon)
	trump_suit_icon.custom_minimum_size = Vector2(40, 40)
	trump_suit_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	trump_suit_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trump_row.add_child(trump_suit_icon)

	var trump_text := VBoxContainer.new()
	trump_text.add_theme_constant_override("separation", 0)
	trump_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trump_row.add_child(trump_text)
	trump_text.add_child(_hud_label("TRUMP", 12, COL_MUTED))

	trump_label.get_parent().remove_child(trump_label)
	trump_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	trump_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trump_label.add_theme_font_size_override("font_size", 20)
	trump_label.add_theme_color_override("font_color", COL_GOLD)
	trump_text.add_child(trump_label)

	leave_button = Button.new()
	leave_button.name = "LeaveButton"
	leave_button.text = "Leave"
	leave_button.anchor_left = 1.0
	leave_button.anchor_right = 1.0
	leave_button.offset_left = -96.0
	leave_button.offset_top = 12.0
	leave_button.offset_right = -14.0
	leave_button.offset_bottom = 50.0
	for state in ["normal", "hover", "pressed"]:
		leave_button.add_theme_stylebox_override(state, _danger_style(state))
	leave_button.add_theme_color_override("font_color", Color(1, 0.92, 0.9))
	leave_button.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	leave_button.pressed.connect(_on_leave_requested)
	hud.add_child(leave_button)

func _danger_style(state: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	match state:
		"hover":
			style.bg_color = Color(0.76, 0.25, 0.22)
		"pressed":
			style.bg_color = Color(0.45, 0.13, 0.12)
		_:
			style.bg_color = Color(0.63, 0.19, 0.17)
	style.border_color = Color(0.85, 0.36, 0.32, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

func _ensure_nameplates() -> void:
	for view_name in seat_order:
		if view_name == "my" or nameplates.has(view_name):
			continue
		var plate := Label.new()
		plate.size = NAMEPLATE_SIZE
		plate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plate.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		plate.add_theme_font_size_override("font_size", 14)
		plate.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		plate.add_theme_constant_override("outline_size", 4)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# A tinted plate behind the name is what actually carries the team
		# colour; the text stays near-white so it is still easy to read.
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(9)
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		plate.add_theme_stylebox_override("normal", style)
		nameplate_styles[view_name] = style

		hud.add_child(plate)
		nameplates[view_name] = plate

	for view_name in nameplates.keys():
		if not seat_order.has(view_name):
			(nameplates[view_name] as Label).queue_free()
			nameplates.erase(view_name)
			nameplate_styles.erase(view_name)

func _team_of_view(view_name: String) -> String:
	return str((seat_to_player.get(view_name, {}) as Dictionary).get("team", ""))

func _is_my_team(view_name: String) -> bool:
	var team := _team_of_view(view_name)
	return team != "" and team == my_team

func _team_color(view_name: String) -> Color:
	return COL_TEAM_MINE if _is_my_team(view_name) else COL_TEAM_THEIRS

func _style_nameplate(view_name: String, plate: Label, is_turn: bool) -> void:
	var style: StyleBoxFlat = nameplate_styles.get(view_name, null)
	if style == null:
		return
	var team := _team_color(view_name)

	if is_turn:
		# On top of the team tint, the active seat gets a gold ring that
		# breathes, so whose turn it is reads at a glance from anywhere on the
		# table rather than only from the colour of the text.
		var glow: float = 0.55 + 0.45 * absf(sin(turn_pulse_t * 3.0))
		style.bg_color = Color(team.r, team.g, team.b, 0.42)
		style.set_border_width_all(3)
		style.border_color = Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, glow)
		plate.add_theme_color_override("font_color", Color(1, 1, 1))
	else:
		style.bg_color = Color(team.r * 0.35, team.g * 0.35, team.b * 0.35, 0.72)
		style.set_border_width_all(2)
		style.border_color = Color(team.r, team.g, team.b, 0.85)
		plate.add_theme_color_override("font_color", Color(0.93, 0.96, 0.98))

func _display_name(view_name: String) -> String:
	# The bottom seat is only "You" to the player sitting in it.
	if view_name == "my" and not is_spectator:
		return "You"
	if view_name == "":
		return "-"
	return str((seat_to_player.get(view_name, {}) as Dictionary).get("name", view_name.capitalize()))

func _current_turn_view() -> String:
	var idx := int(state.get("current_turn_index", -1))
	if idx < 0 or idx >= seat_order.size():
		return ""
	return str(seat_order[idx])

func _update_nameplates() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var turn_view := _current_turn_view()
	var project := func(world: Vector3) -> Vector2: return camera.unproject_position(world)
	var screen := get_viewport().get_visible_rect().size
	for view_name in nameplates.keys():
		var plate: Label = nameplates[view_name]
		var p: Dictionary = seat_to_player.get(view_name, {})
		var text := str(p.get("name", str(view_name).capitalize()))
		if dealer_view == view_name:
			text += "  (Dealer)"
		if not bool(p.get("is_connected", true)) and not bool(p.get("is_bot", false)):
			text += "  [offline]"
		plate.text = text
		plate.position = _nameplate_position(view_name, project, plate.size, screen)
		_style_nameplate(view_name, plate, view_name == turn_view)

func _refresh_hud() -> void:
	_refresh_buttons()
	_refresh_scoreboard()
	_refresh_trump_label()
	_refresh_trump_icon()
	_refresh_phase_message()
	_refresh_turn_timer()

func _refresh_buttons() -> void:
	if is_spectator:
		# Nothing here belongs to a watcher, including the trump-mode dialog,
		# which is the seat holder's decision to make.
		_hide_trump_mode_choice()
		play_button.visible = false
		confirm_hidden_trump_button.visible = false
		open_trump_button.visible = false
		arrange_button.visible = false
		return

	var choosing_mode := phase == "trump_mode_choice"
	var choosing_card := phase == "closed_trump_card_choice" and _is_local_trump_holder()
	var playing := phase == "playing" and my_turn and _can_interact()

	if not choosing_mode:
		_hide_trump_mode_choice()

	if choosing_mode:
		_show_trump_mode_choice()
		play_button.visible = false
		arrange_button.visible = false
		return

	arrange_button.visible = not _hand("my").is_empty() and not _in_trump_setup()

	confirm_hidden_trump_button.text = "Hide This Card"
	confirm_hidden_trump_button.visible = choosing_card
	confirm_hidden_trump_button.disabled = selected_card == null

	play_button.visible = playing
	play_button.disabled = selected_card == null

	open_trump_button.text = "Reveal Trump"
	var can_reveal := playing and trump_mode == "hidden" and not trump_active and lead_suit != "" and not _my_hand_has_suit(lead_suit)
	open_trump_button.visible = can_reveal
	open_trump_button.disabled = not can_reveal

func _my_hand_has_suit(suit: String) -> bool:
	for card in _hand("my"):
		if str(card.suit).to_lower() == suit.to_lower():
			return true
	return false

func _set_hud_value(key: String, text: String, color: Color = COL_TEXT) -> void:
	var label: Label = hud_values.get(key, null)
	if label == null or not is_instance_valid(label):
		return
	label.text = text
	label.add_theme_color_override("font_color", color)

func _refresh_scoreboard() -> void:
	if hud_values.is_empty():
		return

	var scores: Dictionary = state.get("scores", {"A": 0, "B": 0})
	var tens: Dictionary = state.get("captured_10s", {"A": 0, "B": 0})
	var other_team := "B" if my_team == "A" else "A"
	var my_tricks := int(state.get("team_a_trick_count", 0) if my_team == "A" else state.get("team_b_trick_count", 0))
	var their_tricks := int(state.get("team_b_trick_count", 0) if my_team == "A" else state.get("team_a_trick_count", 0))
	var my_tens := int(tens.get(my_team, 0))
	var their_tens := int(tens.get(other_team, 0))

	_set_hud_value("target", "RACE TO %d" % int(state.get("target_score", 15)), COL_MUTED)
	_set_hud_value("you_score", str(scores.get(my_team, 0)), COL_TEXT)
	_set_hud_value("them_score", str(scores.get(other_team, 0)), COL_TEXT)
	_set_hud_value("you_tricks", str(my_tricks), COL_MUTED)
	_set_hud_value("them_tricks", str(their_tricks), COL_MUTED)

	# The 10s decide the game, so they are shown against the court target and
	# flare up as a team closes in on all four.
	_set_hud_value("you_tens", "%d / %d" % [my_tens, TENS_IN_DECK], COL_GOLD if my_tens >= TENS_IN_DECK - 1 else COL_TEXT)
	_set_hud_value("them_tens", "%d / %d" % [their_tens, TENS_IN_DECK], COL_GOLD if their_tens >= TENS_IN_DECK - 1 else COL_TEXT)

	# "Your team" and "Opponents" mean nothing to somebody without a seat, so a
	# watcher gets the sides named instead.
	var you_label: Label = team_row_labels.get("you", null)
	var them_label: Label = team_row_labels.get("them", null)
	if you_label != null and is_instance_valid(you_label):
		you_label.text = ("TEAM %s" % my_team) if is_spectator else "YOUR TEAM"
	if them_label != null and is_instance_valid(them_label):
		them_label.text = ("TEAM %s" % other_team) if is_spectator else "OPPONENTS"

	var turn_view := _current_turn_view()
	_set_hud_value("dealer", _display_name(dealer_view), COL_TEXT)
	_set_hud_value("turn", _display_name(turn_view), COL_GOLD if turn_view == "my" and not is_spectator else COL_TEXT)

func _refresh_trump_label() -> void:
	if trump_active and trump_suit != "":
		trump_label.text = trump_suit.capitalize()
		trump_label.add_theme_color_override("font_color", COL_GOLD)
	else:
		trump_label.text = "Not set"
		trump_label.add_theme_color_override("font_color", COL_MUTED)

func _refresh_trump_icon() -> void:
	if not trump_active or trump_suit == "":
		trump_suit_icon.visible = false
		return
	var path := "res://assets/ui/trump_icons/%s.png" % trump_suit.to_lower()
	if not ResourceLoader.exists(path):
		trump_suit_icon.visible = false
		return
	trump_suit_icon.texture = load(path)
	trump_suit_icon.visible = true

func _animate_trump_icon_in() -> void:
	if trump_icon_tween != null:
		trump_icon_tween.kill()
	trump_suit_icon.visible = true
	trump_suit_icon.modulate.a = 0.0
	trump_suit_icon.scale = Vector2(0.75, 0.75)
	trump_icon_tween = create_tween()
	trump_icon_tween.set_trans(Tween.TRANS_SINE)
	trump_icon_tween.parallel().tween_property(trump_suit_icon, "modulate:a", 1.0, 0.2)
	trump_icon_tween.parallel().tween_property(trump_suit_icon, "scale", Vector2(1.12, 1.12), 0.2)
	trump_icon_tween.tween_property(trump_suit_icon, "scale", Vector2.ONE, 0.12)

# =========================================================================
# between games, and the end of the match
# =========================================================================

func _sync_result_state(target: Dictionary) -> void:
	var new_phase := str(target.get("phase", ""))
	is_host = bool(target.get("is_host", is_host))
	turn_time_limit = maxf(1.0, float(target.get("turn_time_limit", turn_time_limit)))
	choice_time_limit = maxf(1.0, float(target.get("choice_time_limit", choice_time_limit)))
	_arm_choice_deadline(new_phase)

	if new_phase == "game_result":
		if next_game_deadline_ms == 0:
			var delay := float(target.get("next_game_delay", 5.0))
			next_game_deadline_ms = Time.get_ticks_msec() + int(delay * 1000.0)
	else:
		next_game_deadline_ms = 0
		countdown_panel.visible = false

	if new_phase == "match_result":
		_show_match_over(target)
	else:
		_hide_match_over()

func _arm_choice_deadline(for_phase: String) -> void:
	# The server gives the trump holder a fixed window and then chooses for
	# them, so the countdown starts when the phase does.
	var counts: bool = for_phase == "trump_mode_choice" or for_phase == "closed_trump_card_choice" or for_phase == "dealer_draw"
	if not counts:
		choice_deadline_ms = 0
		return
	if for_phase != choice_deadline_phase:
		choice_deadline_phase = for_phase
		choice_deadline_ms = Time.get_ticks_msec() + int(choice_time_limit * 1000.0)

func _update_choice_countdown() -> void:
	if trump_mode_countdown == null or not is_instance_valid(trump_mode_countdown):
		return
	if choice_deadline_ms == 0:
		trump_mode_countdown.text = ""
		return
	var left := float(choice_deadline_ms - Time.get_ticks_msec()) / 1000.0
	if left <= 0.0:
		trump_mode_countdown.text = "Choosing for you..."
		return
	trump_mode_countdown.text = "%d seconds left" % int(ceil(left))

func _update_next_game_countdown() -> void:
	if next_game_deadline_ms == 0:
		return
	var left := float(next_game_deadline_ms - Time.get_ticks_msec()) / 1000.0
	if left <= 0.0:
		countdown_panel.visible = false
		return
	countdown_panel.visible = true
	countdown_label.text = "NEXT GAME IN  %d" % int(ceil(left))

func _build_action_bar() -> void:
	# The bottom buttons used to be pinned to fixed offsets designed for two
	# side by side, so a single button (Hide This Card) sat off to the left of
	# the hand. They now live in a centred row and re-centre themselves
	# whenever the set of visible buttons changes.
	action_bar = HBoxContainer.new()
	action_bar.name = "ActionBar"
	action_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	action_bar.add_theme_constant_override("separation", 14)
	action_bar.anchor_left = 0.5
	action_bar.anchor_right = 0.5
	action_bar.anchor_top = 1.0
	action_bar.anchor_bottom = 1.0
	action_bar.offset_left = -320.0
	action_bar.offset_right = 320.0
	action_bar.offset_top = -72.0
	action_bar.offset_bottom = -22.0
	action_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(action_bar)

	for button in [confirm_hidden_trump_button, play_button, open_trump_button]:
		button.get_parent().remove_child(button)
		button.custom_minimum_size = Vector2(190, 50)
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		action_bar.add_child(button)

	# The reveal is a rare, high-stakes option, so it is the one button on the
	# table that glows for attention.
	reveal_glow_style = StyleBoxFlat.new()
	reveal_glow_style.set_corner_radius_all(12)
	reveal_glow_style.content_margin_left = 20
	reveal_glow_style.content_margin_right = 20
	reveal_glow_style.content_margin_top = 12
	reveal_glow_style.content_margin_bottom = 12
	for state in ["normal", "hover", "pressed"]:
		open_trump_button.add_theme_stylebox_override(state, reveal_glow_style)
	open_trump_button.add_theme_color_override("font_color", Color(0.16, 0.11, 0.02))
	open_trump_button.add_theme_color_override("font_hover_color", Color(0.10, 0.07, 0.01))

func _update_reveal_glow(delta: float) -> void:
	if reveal_glow_style == null or not open_trump_button.visible:
		return
	reveal_pulse_t += delta
	var beat: float = 0.5 + 0.5 * absf(sin(reveal_pulse_t * 3.2))
	reveal_glow_style.bg_color = Color(0.98, 0.72, 0.20).lerp(Color(1.0, 0.90, 0.45), beat)
	reveal_glow_style.set_border_width_all(int(round(2.0 + 2.0 * beat)))
	reveal_glow_style.border_color = Color(1.0, 0.96, 0.72, 0.35 + 0.55 * beat)

func _build_countdown_ui() -> void:
	countdown_panel = PanelContainer.new()
	countdown_panel.name = "NextGameCountdown"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.09, 0.06, 0.9)
	style.border_color = COL_GOLD
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	countdown_panel.add_theme_stylebox_override("panel", style)
	countdown_panel.anchor_left = 0.5
	countdown_panel.anchor_right = 0.5
	countdown_panel.anchor_top = 0.5
	countdown_panel.anchor_bottom = 0.5
	countdown_panel.offset_left = -140.0
	countdown_panel.offset_right = 140.0
	countdown_panel.offset_top = 70.0
	countdown_panel.offset_bottom = 116.0
	countdown_panel.visible = false
	countdown_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(countdown_panel)

	countdown_label = _hud_label("", 20, COL_GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	countdown_panel.add_child(countdown_label)

func _hide_match_over() -> void:
	if match_over_layer != null and is_instance_valid(match_over_layer):
		match_over_layer.queue_free()
	match_over_layer = null

func _show_match_over(target: Dictionary) -> void:
	if match_over_layer != null and is_instance_valid(match_over_layer):
		return

	var result: Dictionary = target.get("last_game_result", {})
	var scores: Dictionary = target.get("scores", {"A": 0, "B": 0})
	var other_team := "B" if my_team == "A" else "A"
	var won := str(result.get("winner", "")) == my_team

	var layer := Control.new()
	layer.name = "MatchOver"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(layer)
	match_over_layer = layer

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var box := VBoxContainer.new()
	box.name = "MatchOverBox"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var headline_text := "YOU WIN THE MATCH" if won else "MATCH LOST"
	var caption_text := "your team  ·  opponents      (first to %d)" % int(target.get("target_score", 15))
	if is_spectator:
		headline_text = "TEAM %s WINS THE MATCH" % str(result.get("winner", my_team))
		caption_text = "team %s  ·  team %s      (first to %d)" % [my_team, other_team, int(target.get("target_score", 15))]

	var headline := _hud_label(headline_text, 54, COL_GOLD if won or is_spectator else COL_THEM, HORIZONTAL_ALIGNMENT_CENTER)
	headline.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	headline.add_theme_constant_override("outline_size", 10)
	box.add_child(headline)

	var score_line := _hud_label("%d  -  %d" % [int(scores.get(my_team, 0)), int(scores.get(other_team, 0))], 40, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	score_line.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	score_line.add_theme_constant_override("outline_size", 8)
	box.add_child(score_line)

	var caption := _hud_label(caption_text, 15, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(caption)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)

	if is_host:
		var again := Button.new()
		again.name = "PlayAgainButton"
		again.text = "Play Again"
		again.theme_type_variation = &"AccentButton"
		again.custom_minimum_size = Vector2(180, 48)
		again.pressed.connect(_on_play_again_pressed)
		buttons.add_child(again)
	else:
		var waiting := _hud_label("Waiting for the host to start a rematch", 15, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		box.add_child(waiting)

	var quit_button := Button.new()
	quit_button.name = "MatchOverLeaveButton"
	quit_button.text = "Back to Menu"
	quit_button.custom_minimum_size = Vector2(180, 48)
	quit_button.pressed.connect(_on_leave_pressed)
	buttons.add_child(quit_button)

	# A watcher has no side, so "you won" confetti would be meaningless.
	if won and not is_spectator:
		_spawn_confetti(layer, 60)

	var fade := layer.create_tween()
	fade.tween_property(dim, "color:a", 0.72, 0.35)

func _on_play_again_pressed() -> void:
	NetworkManager.request_rematch()
	if match_over_layer != null and is_instance_valid(match_over_layer):
		for button in match_over_layer.find_children("*", "Button", true, false):
			(button as Button).disabled = true

# =========================================================================
# court celebration
# =========================================================================

func _check_court_celebration() -> void:
	# last_game_result is cleared when a new game is created, so an empty
	# result is the signal to arm the celebration for the next court.
	var result: Dictionary = state.get("last_game_result", {})
	if result.is_empty():
		court_celebrated = false
		return
	if not bool(result.get("court", false)) or court_celebrated:
		return
	court_celebrated = true
	_celebrate_court(result)

func _celebrate_court(result: Dictionary) -> void:
	if celebration_layer != null and is_instance_valid(celebration_layer):
		celebration_layer.queue_free()

	var won := str(result.get("winner", "")) == my_team

	var layer := Control.new()
	layer.name = "CourtCelebration"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(layer)
	celebration_layer = layer

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var box := VBoxContainer.new()
	box.name = "CourtBanner"
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	# A court is a spectacle whoever takes it, so a watcher gets the full banner
	# with the winning side named rather than "you" or "the opponents".
	var celebrate := won or is_spectator
	var headline_text := "COURT!" if celebrate else "COURT AGAINST YOU"
	var headline := _hud_label(headline_text, 76 if celebrate else 52, COL_GOLD if celebrate else COL_THEM, HORIZONTAL_ALIGNMENT_CENTER)
	headline.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	headline.add_theme_constant_override("outline_size", 12)
	box.add_child(headline)

	var who := "You swept all four 10s" if won else "The opponents swept all four 10s"
	if is_spectator:
		who = "Team %s swept all four 10s" % str(result.get("winner", ""))
	var subtitle := _hud_label(who, 22, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	subtitle.add_theme_constant_override("outline_size", 6)
	box.add_child(subtitle)

	var points := _hud_label("+%d POINTS" % int(result.get("points", 5)), 28, COL_GOLD if celebrate else COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	points.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	points.add_theme_constant_override("outline_size", 8)
	box.add_child(points)

	if bool(result.get("ended_early", false)):
		box.add_child(_hud_label("Game ended early — the court is decided", 16, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	if celebrate:
		_spawn_confetti(layer, 46)

	# The banner has no size until the container has laid it out, so the pop
	# has to wait one frame for a correct pivot.
	await get_tree().process_frame
	if not is_inside_tree() or not is_instance_valid(box):
		return
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2(0.45, 0.45)
	var pop := box.create_tween()
	pop.set_trans(Tween.TRANS_BACK)
	pop.set_ease(Tween.EASE_OUT)
	pop.tween_property(box, "scale", Vector2(1.06, 1.06), 0.35)
	pop.set_trans(Tween.TRANS_SINE)
	pop.tween_property(box, "scale", Vector2.ONE, 0.15)

	var life := layer.create_tween()
	life.tween_property(dim, "color:a", 0.5, 0.25)
	life.tween_interval(COURT_CELEBRATION_TIME)
	life.tween_property(layer, "modulate:a", 0.0, 0.5)
	life.tween_callback(func():
		if is_instance_valid(layer):
			layer.queue_free()
		celebration_layer = null
	)

func _spawn_confetti(layer: Control, count: int) -> void:
	var view_size := layer.get_viewport_rect().size
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		return
	var palette := [COL_GOLD, COL_YOU, COL_THEM, Color(0.55, 0.72, 0.96), Color(1, 1, 1)]
	var origin := Vector2(view_size.x * 0.5, view_size.y * 0.44)

	for i in range(count):
		var piece := ColorRect.new()
		piece.color = palette[i % palette.size()]
		piece.size = Vector2(randf_range(6.0, 12.0), randf_range(10.0, 18.0))
		piece.pivot_offset = piece.size * 0.5
		piece.position = origin
		piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(piece)

		var angle := randf_range(0.0, TAU)
		var burst := origin + Vector2(cos(angle), sin(angle)) * randf_range(140.0, view_size.x * 0.42)
		var fall := Vector2(burst.x + randf_range(-70.0, 70.0), view_size.y + 80.0)

		var flight := piece.create_tween()
		flight.set_trans(Tween.TRANS_QUAD)
		flight.set_ease(Tween.EASE_OUT)
		flight.tween_property(piece, "position", burst, 0.4)
		flight.set_ease(Tween.EASE_IN)
		flight.tween_property(piece, "position", fall, randf_range(1.2, 2.0))

		var spin := piece.create_tween()
		spin.tween_property(piece, "rotation", randf_range(-9.0, 9.0), 2.4)

func _set_phase_message(text: String, color: Color = COL_GOLD) -> void:
	phase_message_panel.visible = true
	phase_message_label.text = text
	phase_message_label.add_theme_color_override("font_color", color)

func _clear_phase_message() -> void:
	phase_message_panel.visible = false
	phase_message_label.text = ""

func _refresh_phase_message() -> void:
	if is_spectator:
		_refresh_spectator_message()
		return

	match phase:
		"dealer_draw":
			if dealer_draw_selected == -1:
				_set_phase_message("Pick a card - the highest card deals")
			else:
				_set_phase_message("Waiting for the other players to pick...")
		"dealer_decided":
			_set_phase_message("%s deals this game" % _display_name(dealer_view))
		"dealing":
			_set_phase_message("Dealing...")
		"trump_mode_choice":
			_show_trump_mode_choice()
		"closed_trump_card_choice":
			if _is_local_trump_holder():
				_set_phase_message("Choose one card to hide as the trump")
			else:
				_set_phase_message("Waiting for %s to hide a trump card" % _display_name(_trump_holder_view()))
		"game_result", "match_result":
			var result: Dictionary = state.get("last_game_result", {})
			if result.is_empty():
				_set_phase_message("Game complete")
			elif bool(result.get("draw", false)):
				_set_phase_message("Draw! No points. Next deal starting...")
			else:
				var winner := str(result.get("winner", ""))
				var won := winner == my_team
				var who := "Your team" if won else "Opponents"
				var points := int(result.get("points", 0))
				if bool(result.get("court", false)):
					var tail := " The game ended right there." if bool(result.get("ended_early", false)) else ""
					var court_color := COL_GOLD if won else COL_THEM
					if phase == "match_result":
						_set_phase_message("COURT! %s took all four 10s (+%d) and won the match!" % [who, points], court_color)
					else:
						_set_phase_message("COURT! %s took all four 10s (+%d).%s Next deal starting..." % [who, points, tail], court_color)
				elif phase == "match_result":
					_set_phase_message("%s won the match! (+%d)" % [who, points], COL_YOU if won else COL_THEM)
				else:
					_set_phase_message("%s won this game (+%d). Next deal starting..." % [who, points], COL_YOU if won else COL_THEM)
		"playing":
			if bool(state.get("revealing_trump", false)):
				_set_phase_message("Trump revealed: %s" % trump_suit.capitalize())
			elif my_turn and not table_busy and _owes_trump():
				_set_phase_message("You opened the trump - play a %s" % trump_suit.capitalize())
			elif my_turn and not table_busy:
				_set_phase_message("Your turn")
			else:
				_clear_phase_message()
		_:
			_clear_phase_message()

func _refresh_spectator_message() -> void:
	# Everything a player is told is phrased around their own hand and turn,
	# none of which a watcher has. Report the table instead.
	match phase:
		"dealer_draw":
			_set_phase_message("Picking a dealer - the highest card deals")
		"dealer_decided":
			_set_phase_message("%s deals this game" % _display_name(dealer_view))
		"dealing":
			_set_phase_message("Dealing...")
		"trump_mode_choice":
			_set_phase_message("%s is choosing open or closed trump" % _display_name(_trump_holder_view()))
		"closed_trump_card_choice":
			_set_phase_message("%s is hiding a trump card" % _display_name(_trump_holder_view()))
		"game_result", "match_result":
			_set_phase_message(_spectator_result_text())
		"playing":
			if bool(state.get("revealing_trump", false)):
				_set_phase_message("Trump revealed: %s" % trump_suit.capitalize())
			else:
				_clear_phase_message()
		_:
			_clear_phase_message()

func _spectator_result_text() -> String:
	var result: Dictionary = state.get("last_game_result", {})
	if result.is_empty():
		return "Game complete"
	if bool(result.get("draw", false)):
		return "Draw! No points."
	var winner := str(result.get("winner", ""))
	var points := int(result.get("points", 0))
	if bool(result.get("court", false)):
		return "COURT! Team %s took all four 10s (+%d)." % [winner, points]
	if phase == "match_result":
		return "Team %s won the match! (+%d)" % [winner, points]
	return "Team %s won this game (+%d)." % [winner, points]

func _build_spectator_badge() -> void:
	# A watcher has no cards and no buttons, so without this the screen is not
	# obviously different from a game you are simply not on turn in.
	if not is_spectator:
		return

	spectator_badge = PanelContainer.new()
	spectator_badge.name = "SpectatorBadge"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.14, 0.9)
	style.border_color = Color(0.36, 0.66, 0.98, 0.85)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	spectator_badge.add_theme_stylebox_override("panel", style)
	spectator_badge.anchor_left = 0.5
	spectator_badge.anchor_right = 0.5
	spectator_badge.anchor_top = 1.0
	spectator_badge.anchor_bottom = 1.0
	spectator_badge.offset_left = -110.0
	spectator_badge.offset_right = 110.0
	spectator_badge.offset_top = -70.0
	spectator_badge.offset_bottom = -28.0
	spectator_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(spectator_badge)

	var label := _hud_label("WATCHING", 16, Color(0.66, 0.83, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spectator_badge.add_child(label)

# =========================================================================
# turn timer
# =========================================================================

func _turn_timer_position(view_name: String, camera: Camera3D) -> Vector2:
	var size := turn_timer_widget.size
	if view_name == "my":
		var anchor := _seat_anchor_position("my").lerp(_trick_slot_position("my"), 0.4)
		return camera.unproject_position(_to_world(anchor)) - size * 0.5

	# For everyone else the ring sits beside their nameplate, which is already
	# placed clear of their cards.
	var plate: Label = nameplates.get(view_name, null)
	var screen := get_viewport().get_visible_rect().size
	if plate == null:
		var project := func(world: Vector3) -> Vector2: return camera.unproject_position(world)
		return _seat_screen_rect(view_name, project).get_center() - size * 0.5

	# Under the name if there is room, otherwise above it. Sideways would run
	# into the cards on a crowded table.
	var pos := Vector2(
		plate.position.x + plate.size.x * 0.5 - size.x * 0.5,
		plate.position.y + plate.size.y + 6.0
	)
	if pos.y + size.y > screen.y - 8.0:
		pos.y = plate.position.y - size.y - 6.0
	pos.x = clampf(pos.x, 6.0, maxf(6.0, screen.x - size.x - 6.0))
	pos.y = clampf(pos.y, 6.0, maxf(6.0, screen.y - size.y - 6.0))
	return pos

func _refresh_turn_timer() -> void:
	# The ring follows whoever the table is waiting on: the player on turn, the
	# player still to pick a dealer-draw card, or the trump holder choosing
	# which card to hide. Every one of those has a server deadline behind it.
	var view := ""
	var limit := turn_time_limit
	match phase:
		"playing":
			view = _current_turn_view()
		"dealer_draw":
			# The ring counts down this client's own pick, so a watcher has
			# nothing for it to count.
			if dealer_draw_selected == -1 and not is_spectator:
				view = "my"
				limit = choice_time_limit
		"closed_trump_card_choice":
			view = _trump_holder_view()
			limit = choice_time_limit

	var should_run := view != "" and not table_busy
	if should_run and (not timer_active or view != timer_view or not is_equal_approx(limit, turn_time_limit_active)):
		timer_view = view
		turn_time_limit_active = limit
		_start_turn_timer()
	elif not should_run and timer_active:
		_stop_turn_timer()

func _start_turn_timer() -> void:
	timer_active = true
	time_left = turn_time_limit_active
	timer_token += 1
	if timer_fade_tween != null:
		timer_fade_tween.kill()
	turn_timer_widget.visible = true
	turn_timer_widget.modulate.a = 0.0
	timer_fade_tween = create_tween()
	timer_fade_tween.tween_property(turn_timer_widget, "modulate:a", 1.0, 0.18)

func _stop_turn_timer() -> void:
	timer_active = false
	timer_view = ""
	timer_token += 1
	timer_pulse_t = 0.0
	turn_timer_widget.scale = Vector2.ONE
	if timer_fade_tween != null:
		timer_fade_tween.kill()
	timer_fade_tween = create_tween()
	timer_fade_tween.tween_property(turn_timer_widget, "modulate:a", 0.0, 0.15)
	timer_fade_tween.tween_callback(func(): turn_timer_widget.visible = false)

func _process(delta: float) -> void:
	turn_pulse_t += delta
	_update_nameplates()
	_update_next_game_countdown()
	_update_choice_countdown()
	_update_reveal_glow(delta)

	if not timer_active:
		return

	time_left = maxf(0.0, time_left - delta)

	var camera := get_viewport().get_camera_3d()
	if camera != null:
		turn_timer_widget.position = _turn_timer_position(timer_view, camera)

	turn_timer_text.text = str(int(ceil(time_left)))
	turn_timer_ring.value = clampf(time_left / turn_time_limit_active, 0.0, 1.0) * 100.0
	var color := Color(0.2, 1.0, 0.2).lerp(Color(1.0, 0.2, 0.2), clampf((5.0 - time_left) / 5.0, 0.0, 1.0))
	turn_timer_text.modulate = color
	turn_timer_ring.tint_progress = color

	if time_left <= 5.0:
		timer_pulse_t += delta * 6.0
		var pulse: float = 1.0 + 0.06 * absf(sin(timer_pulse_t))
		turn_timer_widget.scale = Vector2(pulse, pulse)

# =========================================================================
# misc
# =========================================================================

func _on_leave_requested() -> void:
	# Leaving mid-hand is easy to do by accident and cannot be undone from the
	# other players' point of view, so it asks first.
	if leave_confirm_layer != null and is_instance_valid(leave_confirm_layer):
		return

	var layer := Control.new()
	layer.name = "LeaveConfirm"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(layer)
	leave_confirm_layer = layer

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.66)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.12, 0.09, 0.98)
	style.border_color = Color(0.24, 0.35, 0.29)
	style.set_border_width_all(1)
	style.set_corner_radius_all(16)
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	card.add_theme_stylebox_override("panel", style)
	center.add_child(card)

	var box := VBoxContainer.new()
	box.name = "LeaveConfirmBox"
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)

	box.add_child(_hud_label("Leave the game?", 26, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	var note := "The rest of the table keeps playing and your hand is played for you. Your seat is held if you come back."
	var detail := _hud_label(note, 15, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	detail.custom_minimum_size = Vector2(420, 0)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	box.add_child(spacer)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)

	var stay := Button.new()
	stay.name = "StayButton"
	stay.text = "Keep Playing"
	stay.custom_minimum_size = Vector2(190, 48)
	stay.pressed.connect(_dismiss_leave_confirm)
	row.add_child(stay)

	var go := Button.new()
	go.name = "ConfirmLeaveButton"
	go.text = "Leave"
	go.custom_minimum_size = Vector2(150, 48)
	for state in ["normal", "hover", "pressed"]:
		go.add_theme_stylebox_override(state, _danger_style(state))
	go.add_theme_color_override("font_color", Color(1, 0.92, 0.9))
	go.pressed.connect(_on_leave_pressed)
	row.add_child(go)

func _dismiss_leave_confirm() -> void:
	if leave_confirm_layer != null and is_instance_valid(leave_confirm_layer):
		leave_confirm_layer.queue_free()
	leave_confirm_layer = null

func _on_leave_pressed() -> void:
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")

func _on_connection_lost() -> void:
	table_busy = true
	_stop_turn_timer()
	_refresh_buttons()
	_set_phase_message("Connection lost. Press Leave to return to the menu.")
