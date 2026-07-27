extends SceneTree

# Screen-space layout check. Deals a real game into the real scene, projects
# every card and every HUD element onto the screen through the real camera,
# and asserts that things which must not sit on top of each other do not.
#
# "Looks cluttered" is otherwise untestable, so the rules are written down
# here: hand cards vs piles, names vs cards, cards vs buttons, and everything
# inside the viewport.

const ServerScript = preload("res://scripts/game/Server.gd")

# Elements may touch, but not by more than this many pixels in both axes.
const ALLOWED_OVERLAP := 6.0

# The resolution the game ships at (project.godot). Headless always comes up
# with a square window and refuses to resize, so both the 3D projection and
# the anchored HUD rects are recomputed for this size instead of being read
# off the live viewport.
const VIEW := Vector2(1280, 720)

var server: Node
var nm: Node
var room_ui: Node
var camera: Camera3D
var code := ""
var human_peer := 2
var human_id := "human_1"
var human_seat := ""
var fails: Array = []
var checks := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		fails.append(label)
		print("  FAIL: ", label)

func st() -> Dictionary:
	return server.rooms[code].get("match_state", {})

func srv_room() -> Dictionary:
	return server.rooms[code]

func settle() -> void:
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while room_ui.is_rendering and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

func push() -> void:
	room_ui._on_snapshot_received(server._build_client_snapshot(srv_room(), human_seat))
	await settle()

# --- screen-space helpers -------------------------------------------------

func project(world: Vector3) -> Vector2:
	# Godot's default keep_aspect is KEEP_HEIGHT, so fov is the vertical one.
	var local: Vector3 = camera.global_transform.affine_inverse() * world
	var depth := -local.z
	if depth <= 0.001:
		return Vector2(-99999.0, -99999.0)
	var half_h := tan(deg_to_rad(camera.fov) * 0.5) * depth
	var half_w := half_h * (VIEW.x / VIEW.y)
	return Vector2(VIEW.x * 0.5 * (1.0 + local.x / half_w), VIEW.y * 0.5 * (1.0 - local.y / half_h))

func card_rect(card: Node3D) -> Rect2:
	# Use the scene's own routine: it transforms the card's face by the card's
	# rotation, so it is right for flat cards and for the opponents' standing
	# ones alike. A flat-footprint approximation here would measure a table
	# that is not the one being drawn.
	return room_ui._card_screen_rect(card, func(w: Vector3) -> Vector2: return project(w))

func rects_of(cards: Array) -> Array:
	var out: Array = []
	for card in cards:
		if is_instance_valid(card):
			out.append(card_rect(card))
	return out

func control_rect(control: Control) -> Rect2:
	# Anchored HUD controls are laid out against the live (square) window, so
	# resolve their anchors against the shipping size instead.
	var left: float = control.anchor_left * VIEW.x + control.offset_left
	var top: float = control.anchor_top * VIEW.y + control.offset_top
	var right: float = control.anchor_right * VIEW.x + control.offset_right
	var bottom: float = control.anchor_bottom * VIEW.y + control.offset_bottom
	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))

func plate_rect(view_name: String) -> Rect2:
	# The scene places nameplates through the live (square) viewport, so ask
	# the same placement routine using this test's projection instead.
	var size: Vector2 = room_ui.NAMEPLATE_SIZE
	var placer := func(world: Vector3) -> Vector2: return project(world)
	return Rect2(room_ui._nameplate_position(view_name, placer, size, VIEW), size)

func overlap(a: Rect2, b: Rect2) -> Vector2:
	var inter := a.intersection(b)
	return inter.size

func clashes(a: Rect2, b: Rect2) -> bool:
	var o := overlap(a, b)
	return o.x > ALLOWED_OVERLAP and o.y > ALLOWED_OVERLAP

func worst(group_a: Array, group_b: Array) -> Vector2:
	var biggest := Vector2.ZERO
	for a in group_a:
		for b in group_b:
			var o := overlap(a, b)
			if o.x * o.y > biggest.x * biggest.y:
				biggest = o
	return biggest

func none_clash(group_a: Array, group_b: Array, label: String) -> void:
	var biggest := worst(group_a, group_b)
	var clean: bool = not (biggest.x > ALLOWED_OVERLAP and biggest.y > ALLOWED_OVERLAP)
	ok(clean, "%s (worst overlap %.0fx%.0f px)" % [label, biggest.x, biggest.y])

func _initialize() -> void:
	_run()

func _run() -> void:
	# Headless comes up with a square viewport. The camera projection depends
	# on the aspect ratio, so force the real 1280x720 the game ships with -
	# otherwise this measures a table nobody will ever see.
	root.size = Vector2i(1280, 720)
	await process_frame

	nm = Node.new()
	nm.name = "TestSink"
	root.add_child(nm)
	var net := root.get_node_or_null("NetworkManager")
	ok(net != null, "the NetworkManager autoload is available")
	if net == null:
		_report()
		return

	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	server._server_create_room({"id": human_id, "name": "Human Player"}, {
		"player_count": 4, "target_score": 15,
		"play_direction": "counter_clockwise", "bots_enabled": true
	}, human_peer)
	code = str(server.rooms.keys()[0])
	server._server_start_match(code, human_id, human_peer)
	server._server_claim_dealer_draw_card(code, human_id, 0, human_peer)
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while not srv_room().has("match_state") and Time.get_ticks_msec() < deadline:
		await process_frame
	for p in srv_room().get("players", []):
		if str(p.get("id", "")) == human_id:
			human_seat = str(p.get("seat_id", ""))

	var players_setup: Array = []
	for p in srv_room().get("players", []):
		players_setup.append({
			"id": str(p.get("id", "")), "name": str(p.get("name", "")),
			"seat_id": str(p.get("seat_id", "")), "is_bot": bool(p.get("is_bot", false)),
			"is_local": str(p.get("id", "")) == human_id
		})
	net.pending_match_setup = {
		"players": players_setup, "phase": "trump_mode_choice",
		"dealer_seat_id": str(st().get("dealer_seat_id", "")),
		"trump_holder_seat_id": str(st().get("trump_holder_seat_id", "")),
		"dealer_draw_cards": [], "server_authoritative": true, "is_host": false
	}

	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")
	room_ui = packed.instantiate()
	root.add_child(room_ui)
	await process_frame

	camera = room_ui.get_node_or_null("Camera3D")
	ok(camera != null, "the table camera is available")
	if camera == null:
		_report()
		return

	# Play until every seat holds a full hand and at least one trick has been
	# captured, so piles and captured 10s are on the table too.
	await push()
	var play_deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < play_deadline:
		var s := st()
		if s.is_empty():
			break
		var ph := str(s.get("phase", ""))
		if ph == "game_result" or ph == "match_result":
			break
		if ph != "playing" or bool(s.get("resolving", false)) or bool(s.get("revealing_trump", false)):
			await push()
			continue
		if str(s.get("current_turn_seat_id", "")) != human_seat:
			await push()
			continue
		var hand: Array = s["hands"][human_seat]
		if hand.is_empty():
			break
		var lead := str(s.get("lead_suit", ""))
		var pick: Dictionary = hand[0]
		if lead != "":
			for c in hand:
				if str(c["suit"]) == lead:
					pick = c
					break
		server._server_receive_game_action(code, human_id, {"type": "play_card", "card_id": str(pick["card_id"])}, human_peer)
		await push()
		if room_ui.pile_bundles["A"].size() + room_ui.pile_bundles["B"].size() > 0:
			break

	# Nameplates are placed in _process, so let a frame run with the final
	# table before anything is measured.
	await process_frame
	await process_frame

	var view_size := VIEW
	var screen := Rect2(Vector2.ZERO, view_size)

	# --- gather everything that is on screen ---------------------------------
	var my_cards := rects_of(room_ui.hand_cards["my"])
	ok(my_cards.size() > 0, "the local hand is on the table")

	var opponent_cards: Array = []
	for view in ["right", "top", "left"]:
		for r in rects_of(room_ui.hand_cards[view]):
			opponent_cards.append(r)

	var trick_cards: Array = []
	for entry in room_ui.trick_entries:
		if is_instance_valid(entry["node"]):
			trick_cards.append(card_rect(entry["node"]))

	var piles: Array = []
	var tens: Array = []
	for team in ["A", "B"]:
		for r in rects_of(room_ui.pile_bundles[team]):
			piles.append(r)
		for r in rects_of(room_ui.pile_ten_nodes[team]):
			tens.append(r)

	var trump_slot: Array = []
	if room_ui.hidden_trump_node != null and is_instance_valid(room_ui.hidden_trump_node):
		trump_slot.append(card_rect(room_ui.hidden_trump_node))
	else:
		# Nothing is set aside in an open-trump game; check the slot anyway.
		var slot_position: Vector3 = room_ui.hidden_trump_slot.position
		trump_slot.append(card_rect_at(slot_position))

	var plates: Array = []
	for view in room_ui.nameplates.keys():
		plates.append(plate_rect(str(view)))

	var buttons: Array = []
	for control in [room_ui.play_button, room_ui.arrange_button, room_ui.confirm_hidden_trump_button, room_ui.open_trump_button, room_ui.leave_button]:
		buttons.append(control_rect(control))

	var score_panel := [control_rect(room_ui.score_panel)]
	var trump_chip := [control_rect(room_ui.trump_panel)]
	var banner := [control_rect(room_ui.phase_message_panel)]
	var panels: Array = score_panel + trump_chip + banner

	# --- the rules -----------------------------------------------------------
	none_clash(my_cards, piles, "the local hand does not sit on a captured pile")
	none_clash(my_cards, tens, "the local hand does not sit on the captured 10s")
	none_clash(my_cards, trump_slot, "the local hand does not sit on the hidden trump slot")
	none_clash(my_cards, trick_cards, "the local hand does not sit on the trick")
	none_clash(my_cards, buttons, "the local hand does not sit under the action buttons")
	none_clash(my_cards, plates, "the local hand does not sit under a nameplate")
	none_clash(my_cards, panels, "the local hand does not sit under a HUD panel")
	none_clash(trump_slot, trump_chip, "the trump chip does not cover the hidden trump slot")
	none_clash(tens, panels, "the captured 10s do not sit under a HUD panel")
	none_clash(piles, panels, "the captured piles do not sit under a HUD panel")
	none_clash(trump_chip, buttons, "the trump chip does not overlap the action buttons")
	no_self_clash(panels, "the HUD panels do not overlap each other")

	# The between-games countdown is hidden during play, but it shares the
	# table with the hand and the piles when it does show (an early court
	# leaves cards in hand), so its slot is checked here. It is deliberately
	# not checked against the trick: the trick is always cleared by then.
	var countdown := [control_rect(room_ui.countdown_panel)]
	none_clash(countdown, my_cards, "the next-game countdown does not sit on the local hand")
	none_clash(countdown, piles, "the next-game countdown does not sit on a captured pile")
	none_clash(countdown, tens, "the next-game countdown does not sit on the captured 10s")
	none_clash(countdown, panels, "the next-game countdown does not sit on another panel")
	none_clash(countdown, buttons, "the next-game countdown does not sit on the action buttons")

	none_clash(plates, opponent_cards, "nameplates do not sit on the opponents' cards")
	none_clash(plates, trick_cards, "nameplates do not sit on the trick")
	none_clash(plates, piles, "nameplates do not sit on a captured pile")
	none_clash(plates, tens, "nameplates do not sit on the captured 10s")
	none_clash(plates, panels, "nameplates do not sit under a HUD panel")
	none_clash(plates, buttons, "nameplates do not sit under the action buttons")
	no_self_clash(plates, "two nameplates do not sit on each other")

	none_clash(opponent_cards, panels, "no HUD panel covers the opponents' cards")
	none_clash(opponent_cards, trick_cards, "the opponents' cards do not sit on the trick")
	none_clash(opponent_cards, piles, "the opponents' cards do not sit on a captured pile")

	none_clash(trick_cards, piles, "the trick does not sit on a captured pile")
	none_clash(trick_cards, banner, "the message banner does not cover the trick")
	none_clash(piles, tens, "a captured pile does not cover its own 10s")
	none_clash(piles, trump_slot, "the hidden trump slot is clear of the piles")

	# The captured pile steps forward as it grows, so a single bundle proves
	# nothing. Check where a full 13-trick stack would actually end up.
	var full_piles: Array = []
	for team in ["A", "B"]:
		for i in [0, 6, 12]:
			full_piles.append(card_rect_at(room_ui._pile_position(team, i)))
	none_clash(my_cards, full_piles, "a full 13-trick pile stays clear of the local hand")
	none_clash(full_piles, buttons, "a full 13-trick pile stays clear of the action buttons")
	none_clash(full_piles, trick_cards, "a full 13-trick pile stays clear of the trick")
	none_clash(full_piles, plates, "a full 13-trick pile stays clear of the nameplates")
	var full_off := 0
	for r in full_piles:
		if not screen.encloses(r):
			full_off += 1
	ok(full_off == 0, "a full 13-trick pile stays on screen (%d corners off)" % full_off)

	# --- nothing may fall off the screen -------------------------------------
	var off_screen := 0
	var groups := {
		"hand": my_cards, "opponents": opponent_cards, "trick": trick_cards,
		"piles": piles, "10s": tens, "trump slot": trump_slot
	}
	var worst_note := ""
	for key in groups.keys():
		for r in groups[key]:
			if not screen.encloses(r):
				off_screen += 1
				worst_note = "%s at %.0f,%.0f %.0fx%.0f" % [str(key), r.position.x, r.position.y, r.size.x, r.size.y]
	ok(off_screen == 0, "every card stays inside the %.0fx%.0f screen (%d off, e.g. %s)" % [view_size.x, view_size.y, off_screen, worst_note])

	# --- the table has to fill the screen and sit in the middle of it ---------
	var content := Rect2()
	var have_content := false
	for group in [my_cards, opponent_cards, trick_cards, piles, tens, trump_slot]:
		for r in group:
			if have_content:
				content = content.merge(r)
			else:
				content = r
				have_content = true
	var top_gap := content.position.y
	var bottom_gap := view_size.y - content.end.y
	ok(absf(top_gap - bottom_gap) < 60.0, "the table is vertically centred (%.0f px above, %.0f px below)" % [top_gap, bottom_gap])
	ok(content.size.y > view_size.y * 0.70, "the table fills the screen vertically (%.0f of %.0f px)" % [content.size.y, view_size.y])
	ok(content.size.x > view_size.x * 0.70, "the table fills the screen horizontally (%.0f of %.0f px)" % [content.size.x, view_size.x])

	# Pull the camera back and the cards stop being readable; hold the line.
	var tallest := 0.0
	for r in my_cards:
		tallest = maxf(tallest, r.size.y)
	ok(tallest >= 100.0, "cards in hand are big enough to read (%.0f px tall)" % tallest)

	var plates_off := 0
	var plate_note := ""
	for r in plates:
		if not screen.encloses(r):
			plates_off += 1
			plate_note = "%.0f,%.0f %.0fx%.0f" % [r.position.x, r.position.y, r.size.x, r.size.y]
	ok(plates_off == 0, "every nameplate stays inside the screen (%d off, e.g. %s)" % [plates_off, plate_note])

	_report()

func card_rect_at(local_position: Vector3) -> Rect2:
	var probe: Node3D = room_ui.CARD_SCENE.instantiate()
	room_ui.cards_node.add_child(probe)
	probe.position = local_position
	var rect := card_rect(probe)
	probe.queue_free()
	return rect

func no_self_clash(group: Array, label: String) -> void:
	var biggest := Vector2.ZERO
	for i in range(group.size()):
		for j in range(i + 1, group.size()):
			var o := overlap(group[i], group[j])
			if o.x * o.y > biggest.x * biggest.y:
				biggest = o
	var clean: bool = not (biggest.x > ALLOWED_OVERLAP and biggest.y > ALLOWED_OVERLAP)
	ok(clean, "%s (worst overlap %.0fx%.0f px)" % [label, biggest.x, biggest.y])

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_LAYOUT_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
