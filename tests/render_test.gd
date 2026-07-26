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
	var config := ConfigFile.new()
	config.set_value("match", "setup", {
		"players": players_setup,
		"phase": "trump_mode_choice",
		"dealer_seat_id": str(st().get("dealer_seat_id", "")),
		"trump_holder_seat_id": str(st().get("trump_holder_seat_id", "")),
		"dealer_draw_cards": [],
		"server_authoritative": true,
		"is_host": false
	})
	config.save("user://match_setup.cfg")

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

	var my_face_up := true
	for c in room_ui.hand_cards["my"]:
		if not c.is_face_up:
			my_face_up = false
	ok(my_face_up, "my own cards are revealed after the deal")

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
			var deadline := Time.get_ticks_msec() + 15000
			while str(st().get("phase", "")) != "playing" and Time.get_ticks_msec() < deadline:
				await process_frame
			await push_snapshot()

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
