extends SceneTree

# Feeds real server snapshots into the real GameRoom3D scene and checks that
# the table is animated incrementally: card nodes must be reused between
# snapshots (not re-created, which is what made every move look like a
# fresh deal), opponents' cards must stay face down, and completed tricks
# must end up in a captured pile.

const ServerScript = preload("res://scripts/game/Server.gd")

var server: Node
var nm: Node
var room_ui: Node
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

func st_snapshot() -> Dictionary:
	return server._build_client_snapshot(srv_room(), human_seat)["game_state"]

func srv_room() -> Dictionary:
	return server.rooms[code]

func push_snapshot() -> void:
	room_ui._on_snapshot_received(server._build_client_snapshot(srv_room(), human_seat))
	await settle()

func settle() -> void:
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while room_ui.is_rendering and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

func ids_of(view: String) -> Array:
	var out: Array = []
	for c in room_ui.hand_cards.get(view, []):
		out.append(c.get_instance_id())
	return out

func _initialize() -> void:
	_run()

func _run() -> void:
	nm = Node.new()
	nm.name = "NetworkManager"
	root.add_child(nm)
	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	# --- start a real 4-player game (1 human + 3 bots) ---
	server._server_create_room({"id": human_id, "name": "Human"}, {
		"player_count": 4, "target_score": 15,
		"play_direction": "counter_clockwise", "bots_enabled": true
	}, human_peer)
	code = str(server.rooms.keys()[0])
	server._server_start_match(code, human_id, human_peer)
	server._server_claim_dealer_draw_card(code, human_id, 0, human_peer)
	await process_frame
	# the server holds on the finished draw before it deals
	var wait_deadline := Time.get_ticks_msec() + 15000
	while not srv_room().has("match_state") and Time.get_ticks_msec() < wait_deadline:
		await process_frame
	for p in srv_room().get("players", []):
		if str(p.get("id", "")) == human_id:
			human_seat = str(p.get("seat_id", ""))

	# --- bring up the real game scene for the human ---
	var players_setup: Array = []
	for p in srv_room().get("players", []):
		players_setup.append({
			"id": str(p.get("id", "")),
			"name": str(p.get("name", "")),
			"seat_id": str(p.get("seat_id", "")),
			"is_bot": bool(p.get("is_bot", false)),
			"is_local": str(p.get("id", "")) == human_id
		})
	var net := root.get_node_or_null("NetworkManager")
	ok(net != null, "the NetworkManager autoload is available")
	if net == null:
		quit(1)
		return
	net.pending_match_setup = {
		"players": players_setup,
		"phase": "trump_mode_choice",
		"dealer_seat_id": str(st().get("dealer_seat_id", "")),
		"trump_holder_seat_id": str(st().get("trump_holder_seat_id", "")),
		"dealer_draw_cards": [],
		"server_authoritative": true,
		"is_host": false
	}

	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")
	room_ui = packed.instantiate()
	root.add_child(room_ui)
	await process_frame
	ok(room_ui != null, "the game scene loads")

	# --- first paint: the opening deal, sampled while it is running ---
	var deal_started := Time.get_ticks_msec()
	room_ui._on_snapshot_received(server._build_client_snapshot(srv_room(), human_seat))
	await process_frame

	# Half a second in, a staggered deal must still have cards waiting at the
	# deck. If every card moved at once this is zero.
	var sample_deadline := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < sample_deadline:
		await process_frame
	var deck_pos: Vector3 = room_ui.deck_point.position
	var waiting_at_deck := 0
	var moved := 0
	for view in room_ui.seat_order:
		for c in room_ui.hand_cards.get(view, []):
			if c.position.distance_to(deck_pos) < 0.05:
				waiting_at_deck += 1
			else:
				moved += 1
	ok(waiting_at_deck > 0, "cards are still waiting at the deck mid-deal (deal is staggered)")
	ok(moved > 0, "cards have started moving mid-deal")

	await settle()
	var deal_ms := Time.get_ticks_msec() - deal_started
	ok(deal_ms > 1000, "the opening deal takes real time (%d ms)" % deal_ms)

	var phase := str(st().get("phase", ""))
	var expected_my: int = (st()["hands"][human_seat] as Array).size()
	ok(room_ui.hand_cards["my"].size() == expected_my, "my hand is drawn with %d cards" % expected_my)

	var opp_ok := true
	var facedown_ok := true
	var compact_ok := true
	for view in ["right", "top", "left"]:
		var abs_seat := str(room_ui.local_view_to_abs[view])
		var server_count: int = (st()["hands"][abs_seat] as Array).size()
		var drawn: int = room_ui.hand_cards[view].size()
		if drawn != mini(server_count, room_ui.MAX_OPPONENT_CARDS):
			opp_ok = false
		if drawn > room_ui.MAX_OPPONENT_CARDS:
			compact_ok = false
		for c in room_ui.hand_cards[view]:
			if c.is_face_up:
				facedown_ok = false
	ok(opp_ok, "opponent stacks are drawn at the capped size")
	ok(compact_ok, "opponent hands never draw more than %d cards" % room_ui.MAX_OPPONENT_CARDS)
	ok(facedown_ok, "opponent cards are face down")

	# the capped stack must also be physically tight
	var widest := 0.0
	for view in ["right", "top", "left"]:
		var cards: Array = room_ui.hand_cards[view]
		if cards.size() < 2:
			continue
		var span: float = cards[0].home_position.distance_to(cards[cards.size() - 1].home_position)
		widest = maxf(widest, span)
	ok(widest < 1.0, "opponent hands stay compact (widest span %.2f)" % widest)

	# The closed trump is picked blind, so the first batch must stay face down
	# until the trump is settled - including the local player's own cards.
	if phase == "trump_mode_choice" or phase == "closed_trump_card_choice":
		var my_hidden := true
		var leaked_face := false
		for c in room_ui.hand_cards["my"]:
			if c.is_face_up:
				my_hidden = false
		for card_state_raw in st_snapshot()["hands"]["my"]:
			var cs: Dictionary = card_state_raw
			if not bool(cs.get("face_hidden", false)):
				leaked_face = true
		ok(my_hidden, "my first batch stays face down during the trump setup")
		ok(not leaked_face, "the server does not send my card faces during the trump setup")

	# --- resending the same snapshot must not redraw anything ---
	var before_ids := ids_of("my")
	await push_snapshot()
	ok(ids_of("my") == before_ids, "re-sending a snapshot does not re-deal my hand")
	ok(room_ui.hand_cards["my"].size() == before_ids.size(), "hand size is stable across identical snapshots")

	# --- finish the trump setup, then check the remaining deal ---
	if phase == "trump_mode_choice":
		var holder := str(st().get("trump_holder_seat_id", ""))
		if holder == human_seat:
			server._server_choose_trump_mode(code, human_id, "hidden", human_peer)
			await push_snapshot()
			ok(str(st().get("phase", "")) == "closed_trump_card_choice", "closed trump asks for a card")
			var hand: Array = st()["hands"][human_seat]
			var hidden_id := str(hand[0]["card_id"])
			var ids_before_hide := ids_of("my")
			server._server_receive_game_action(code, human_id, {"type": "confirm_hidden_trump", "card_id": hidden_id}, human_peer)
			await push_snapshot()
			ok(room_ui.hidden_trump_node != null, "the hidden trump card moves to its slot")
			if room_ui.hidden_trump_node != null:
				ok(not room_ui.hidden_trump_node.is_face_up, "the hidden trump card stays face down")
			var kept := 0
			for id in ids_of("my"):
				if ids_before_hide.has(id):
					kept += 1
			ok(kept == ids_before_hide.size() - 1, "only the hidden card leaves my hand")
		else:
			var deadline := Time.get_ticks_msec() + 25000
			while str(st().get("phase", "")) != "playing" and Time.get_ticks_msec() < deadline:
				await process_frame
			await push_snapshot()

	# --- once the trump is settled my hand must be revealed ---
	var deadline_play := Time.get_ticks_msec() + 25000
	while str(st().get("phase", "")) != "playing" and Time.get_ticks_msec() < deadline_play:
		await process_frame
	await push_snapshot()

	var revealed_ok := true
	var faces_ok := true
	var server_hand: Array = st_snapshot()["hands"]["my"]
	var server_by_id := {}
	for card_state_raw in server_hand:
		var cs: Dictionary = card_state_raw
		server_by_id[str(cs.get("card_id", ""))] = cs
	for c in room_ui.hand_cards["my"]:
		if not c.is_face_up:
			revealed_ok = false
		var cs2: Dictionary = server_by_id.get(str(c.card_id), {})
		if cs2.is_empty() or str(c.suit) != str(cs2.get("suit", "")) or str(c.rank) != str(cs2.get("rank", "")):
			faces_ok = false
	ok(revealed_ok, "my hand is revealed once the trump is settled")
	ok(faces_ok, "revealed cards show the real suit and rank from the server")

	var ids_after_deal := ids_of("my")
	ok(room_ui.hand_cards["my"].size() == (st()["hands"][human_seat] as Array).size(), "my hand matches the server after the full deal")

	# --- play the game far enough to capture a trick ---
	var captured_any := false
	var identity_kept := true
	var deadline2 := Time.get_ticks_msec() + 120000
	var prev_ids := ids_of("my")

	while Time.get_ticks_msec() < deadline2:
		var s := st()
		if s.is_empty():
			break
		if str(s.get("phase", "")) != "playing":
			break
		if bool(s.get("resolving", false)) or bool(s.get("revealing_trump", false)):
			await push_snapshot()
			continue
		if str(s.get("current_turn_seat_id", "")) != human_seat:
			await push_snapshot()
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

		# cards that stay in my hand must keep the same nodes
		prev_ids = ids_of("my")
		server._server_receive_game_action(code, human_id, {"type": "play_card", "card_id": str(pick["card_id"])}, human_peer)
		await push_snapshot()
		for id in ids_of("my"):
			if not prev_ids.has(id):
				identity_kept = false

		var team_a: int = room_ui.pile_bundles["A"].size()
		var team_b: int = room_ui.pile_bundles["B"].size()
		if team_a + team_b > 0:
			captured_any = true
			break

	ok(identity_kept, "cards already in my hand are never re-created while playing")
	ok(captured_any, "a completed trick is moved into a captured pile")

	var total_bundles: int = room_ui.pile_bundles["A"].size() + room_ui.pile_bundles["B"].size()
	var server_tricks: int = int(st()["captured_tricks"]["A"]) + int(st()["captured_tricks"]["B"])
	ok(total_bundles == server_tricks, "the captured piles match the server trick count")
	ok(room_ui.trick_entries.size() == (st().get("trick_cards", []) as Array).size(), "the centre trick matches the server")

	# 10s captured so far must be shown face up beside the pile
	var shown_tens: int = room_ui.pile_ten_nodes["A"].size() + room_ui.pile_ten_nodes["B"].size()
	var server_tens: int = int(st()["captured_10s"]["A"]) + int(st()["captured_10s"]["B"])
	ok(shown_tens == server_tens, "captured 10s are displayed on the piles")

	# --- the scoreboard reads back the state that is drawn -------------------
	var drawn: Dictionary = room_ui.state
	var my_team: String = str(room_ui.my_team)
	var other_team := "B" if my_team == "A" else "A"
	var drawn_tens: Dictionary = drawn.get("captured_10s", {"A": 0, "B": 0})
	var my_tricks: int = int(drawn.get("team_a_trick_count", 0) if my_team == "A" else drawn.get("team_b_trick_count", 0))
	var their_tricks: int = int(drawn.get("team_b_trick_count", 0) if my_team == "A" else drawn.get("team_a_trick_count", 0))

	ok(room_ui.hud_values.has("you_score") and room_ui.hud_values.has("them_tens"), "the scoreboard is built from labelled cells")
	ok(str(room_ui.hud_values["you_tricks"].text) == str(my_tricks), "the scoreboard shows my team's tricks")
	ok(str(room_ui.hud_values["them_tricks"].text) == str(their_tricks), "the scoreboard shows the opponents' tricks")
	ok(str(room_ui.hud_values["you_tens"].text) == "%d / 4" % int(drawn_tens.get(my_team, 0)), "my 10s are shown against the court target")
	ok(str(room_ui.hud_values["them_tens"].text) == "%d / 4" % int(drawn_tens.get(other_team, 0)), "opponent 10s are shown against the court target")
	ok(str(room_ui.hud_values["target"].text) == "RACE TO %d" % int(drawn.get("target_score", 15)), "the scoreboard shows the target score")
	ok(str(room_ui.hud_values["dealer"].text) == room_ui._display_name(room_ui.dealer_view), "the scoreboard names the dealer")

	await lead_suit_chip_check()

	# --- winning a court is celebrated ---------------------------------------
	var court_snapshot: Dictionary = server._build_client_snapshot(srv_room(), human_seat)
	var court_state: Dictionary = court_snapshot["game_state"]
	court_state["phase"] = "game_result"
	court_state["last_game_result"] = {
		"winner": my_team, "court": true, "points": 5,
		"draw": false, "ended_early": true,
		"captured_10s": {my_team: 4, other_team: 0},
		"captured_tricks": {"A": 3, "B": 2}
	}
	court_snapshot["game_state"] = court_state

	# Start from a clean slate: a single trick above could legitimately have
	# swept all four 10s and fired the celebration already.
	if room_ui.celebration_layer != null and is_instance_valid(room_ui.celebration_layer):
		room_ui.celebration_layer.queue_free()
	room_ui.celebration_layer = null
	room_ui.court_celebrated = false
	await process_frame
	ok(room_ui.celebration_layer == null, "the celebration overlay starts cleared")

	room_ui._on_snapshot_received(court_snapshot)
	await settle()
	await process_frame

	ok(room_ui.celebration_layer != null and is_instance_valid(room_ui.celebration_layer), "a court raises a celebration overlay")
	if room_ui.celebration_layer == null:
		_report()
		return

	ok(room_ui.celebration_layer.find_child("CourtBanner", true, false) != null, "the celebration shows a court banner")
	var confetti := 0
	for child in room_ui.celebration_layer.get_children():
		if child is ColorRect and (child as ColorRect).color.a > 0.9:
			confetti += 1
	ok(confetti > 0, "winning a court throws confetti")
	ok(room_ui.phase_message_panel.visible, "the message banner is shown once the game is decided")
	ok(str(room_ui.phase_message_label.text).contains("COURT"), "the banner message calls out the court")

	# The same result resent must not stack a second overlay.
	var layer_id: int = room_ui.celebration_layer.get_instance_id()
	room_ui._on_snapshot_received(court_snapshot)
	await settle()
	ok(room_ui.celebration_layer.get_instance_id() == layer_id, "a resent result does not restack the celebration")

	# A fresh game clears the result and re-arms the celebration.
	var reset_snapshot: Dictionary = court_snapshot.duplicate(true)
	var reset_state: Dictionary = reset_snapshot["game_state"]
	reset_state["last_game_result"] = {}
	reset_state["phase"] = "playing"
	reset_snapshot["game_state"] = reset_state
	room_ui._on_snapshot_received(reset_snapshot)
	await settle()
	ok(not room_ui.court_celebrated, "a new game re-arms the celebration")
	ok(not str(room_ui.phase_message_label.text).contains("COURT"), "the court message clears when a new game starts")

	await spectator_view_check(net)

	_report()

# --- the suit that is being followed ---------------------------------------

func lead_suit_chip_check() -> void:
	# What you may play is decided by two suits: the trump, and the suit led
	# this trick. The trump had a chip; the lead suit could only be learned by
	# picking an illegal card and being told off.
	var snapshot: Dictionary = server._build_client_snapshot(srv_room(), human_seat)
	var s: Dictionary = snapshot["game_state"]
	s["phase"] = "playing"
	s["current_lead_suit"] = "hearts"
	s["trick_is_resolving"] = false
	s["revealing_trump"] = false
	snapshot["game_state"] = s
	room_ui._on_snapshot_received(snapshot)
	await settle()

	ok(room_ui.lead_label != null and room_ui.lead_suit_icon != null, "the chip carries a lead-suit row")
	if room_ui.lead_label == null:
		return
	ok(str(room_ui.lead_label.text) == "Hearts", "it names the suit that was led")
	ok(room_ui.lead_suit_icon.visible, "and shows its icon")
	ok(room_ui.lead_suit_icon.texture != null, "which is a real texture, not a blank slot")

	# The suit art is over 1100 px square. A TextureRect reports its texture's
	# size as its minimum unless told not to, and custom_minimum_size is a
	# floor rather than a ceiling - so the icon has to be measured as drawn,
	# not trusted to be the size it was asked for.
	await process_frame
	for pair in [["trump", room_ui.trump_suit_icon], ["lead", room_ui.lead_suit_icon]]:
		var which := str(pair[0])
		var icon: TextureRect = pair[1]
		ok(icon.texture == null or icon.texture.get_width() > 200, "the %s icon really is drawn from oversized art" % which)
		ok(icon.size.x <= 64.0 and icon.size.y <= 64.0,
			"the %s icon is drawn at chip size, not the texture's own (got %.0fx%.0f)" % [which, icon.size.x, icon.size.y])

	# And the chip itself must still be the size its offsets ask for. The
	# layout suite measures panels from their anchors, so a container dragged
	# open by its own contents is invisible to it - this is where that shows.
	var chip: Control = room_ui.lead_panel
	var asked := Vector2(chip.offset_right - chip.offset_left, chip.offset_bottom - chip.offset_top)
	ok(chip.size.y <= asked.y + 1.0, "the lead chip is not dragged open by its contents (%.0f vs %.0f)" % [chip.size.y, asked.y])
	ok(chip.size.x <= asked.x + 1.0, "nor stretched sideways by them")
	ok(room_ui.lead_suit_icon.size.y <= chip.size.y, "the lead icon fits inside its chip")

	# Gold while this hand still holds the suit and so must follow it; plain
	# once it is void and free to play anything.
	var holds := bool(room_ui._my_hand_has_suit("hearts"))
	var colour: Color = room_ui.lead_label.get_theme_color("font_color")
	ok(is_equal_approx(colour.r, room_ui.COL_GOLD.r) == holds, "the suit is highlighted only while this hand is bound to follow it")

	# Between tricks there is nothing to follow yet.
	var open_snapshot: Dictionary = snapshot.duplicate(true)
	var open_state: Dictionary = open_snapshot["game_state"]
	open_state["current_lead_suit"] = ""
	open_snapshot["game_state"] = open_state
	room_ui._on_snapshot_received(open_snapshot)
	await settle()
	ok(str(room_ui.lead_label.text) == "Open", "with no card led yet the trick reads as open")
	ok(not room_ui.lead_suit_icon.visible, "and no suit icon is shown")

# --- watching the same table without a seat --------------------------------

func spectator_view_check(net: Node) -> void:
	# A watcher renders the same table, but the seat drawn at the bottom of the
	# screen belongs to somebody else: nothing there may be face up or clickable.
	var players_setup: Array = []
	for p in srv_room().get("players", []):
		players_setup.append({
			"id": str(p.get("id", "")),
			"name": str(p.get("name", "")),
			"seat_id": str(p.get("seat_id", "")),
			"is_bot": bool(p.get("is_bot", false)),
			"is_local": false
		})
	net.pending_match_setup = {
		"players": players_setup,
		"phase": "server_match",
		"dealer_seat_id": str(st().get("dealer_seat_id", "")),
		"trump_holder_seat_id": str(st().get("trump_holder_seat_id", "")),
		"dealer_draw_cards": [],
		"is_spectator": true,
		"is_host": false
	}
	net.latest_game_state_snapshot = {}

	var watcher: Node = load("res://scenes/game/GameRoom3D.tscn").instantiate()
	root.add_child(watcher)
	await process_frame
	ok(bool(watcher.is_spectator), "the game scene knows it is being watched")

	watcher._on_snapshot_received(server._build_spectator_snapshot(srv_room()))
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while watcher.is_rendering and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

	var bottom: Array = watcher.hand_cards.get("my", [])
	ok(not bottom.is_empty(), "the bottom seat is still drawn")
	var face_up := 0
	var clickable := 0
	for card in bottom:
		if card.is_face_up:
			face_up += 1
		if card.clickable:
			clickable += 1
	ok(face_up == 0, "the bottom seat's cards stay face down for a watcher")
	ok(clickable == 0, "and cannot be picked up")
	ok(bottom.size() <= watcher._max_opponent_cards(), "the bottom seat is capped like every other seat")

	# Idle table, and a snapshot that puts the bottom seat on turn: a seated
	# player would be free to act here, so this is where a watcher must not be.
	var on_turn: Dictionary = server._build_spectator_snapshot(srv_room())
	var on_turn_state: Dictionary = on_turn["game_state"]
	on_turn_state["phase"] = "playing"
	on_turn_state["current_turn_index"] = 0
	on_turn_state["trick_is_resolving"] = false
	on_turn_state["revealing_trump"] = false
	on_turn["game_state"] = on_turn_state
	watcher._on_snapshot_received(on_turn)
	await process_frame
	var turn_deadline := Time.get_ticks_msec() + 20000
	while watcher.is_rendering and Time.get_ticks_msec() < turn_deadline:
		await process_frame
	await process_frame

	ok(not watcher.my_turn, "a watcher is never on turn, whatever the snapshot says")
	ok(not watcher.table_busy, "the table really is idle for this check")
	ok(not watcher._can_interact(), "a watcher can never act on an idle table")
	ok(not watcher.play_button.visible, "no play button")
	ok(not watcher.open_trump_button.visible, "no reveal-trump button")
	ok(not watcher.confirm_hidden_trump_button.visible, "no hide-trump button")
	ok(not watcher.arrange_button.visible, "no sort button for a hand they do not hold")
	ok(watcher.spectator_badge != null and watcher.spectator_badge.visible, "the screen says it is watching")
	ok(watcher._display_name("my") != "You", "the bottom seat is named, not called 'You'")

	# Every seat on a watcher's table belongs to somebody, so every seat needs
	# a name. The bottom one used to be skipped, because for a player it is
	# themselves - which is the one missing name tag.
	ok(watcher.nameplates.size() == watcher.seat_order.size(), "every seat carries a nameplate, the bottom one included")
	var bottom_plate: Label = watcher.nameplates.get("my", null)
	ok(bottom_plate != null, "the bottom seat has a nameplate at all")
	if bottom_plate != null:
		watcher._update_nameplates()
		var seated_name := str((watcher.seat_to_player.get("my", {}) as Dictionary).get("name", ""))
		ok(seated_name != "" and str(bottom_plate.text).contains(seated_name), "and it shows that player's real name")
		var view := watcher.get_viewport().get_visible_rect().size
		var plate_rect := Rect2(bottom_plate.position, bottom_plate.size)
		ok(plate_rect.position.x >= 0.0 and plate_rect.end.x <= view.x, "the bottom nameplate stays on screen horizontally")
		ok(plate_rect.position.y >= 0.0 and plate_rect.end.y <= view.y, "and vertically")

	# Clicking anyway must do nothing.
	var current: Array = watcher.hand_cards.get("my", [])
	if not current.is_empty():
		watcher._on_card_clicked(current[0])
		ok(watcher.selected_card == null, "clicking a card a watcher does not own selects nothing")

	watcher.queue_free()
	await process_frame

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_RENDER_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
