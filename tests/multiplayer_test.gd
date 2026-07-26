extends SceneTree

# Two human clients + two bots, both clients rendered in one process from
# their own server snapshots. Catches seat-mapping desyncs: the two players
# must agree on who the dealer and the trump holder are, and exactly one of
# them may believe it is the trump holder.

const ServerScript = preload("res://scripts/game/Server.gd")

var server: Node
var nm: Node
var net: Node          # the real NetworkManager autoload
var code := ""
var client_a: Node
var client_b: Node
var seat_a := ""
var seat_b := ""
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

func snapshot_for(seat_id: String) -> Dictionary:
	return server._build_client_snapshot(srv_room(), seat_id)

func settle(client: Node) -> void:
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while client.is_rendering and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

func player_by_seat(seat_id: String) -> Dictionary:
	for p in srv_room().get("players", []):
		if str(p.get("seat_id", "")) == seat_id:
			return p
	return {}

func setup_for(seat_id: String) -> Dictionary:
	var players_setup: Array = []
	for p in srv_room().get("players", []):
		players_setup.append({
			"id": str(p.get("id", "")),
			"name": str(p.get("name", "")),
			"seat_id": str(p.get("seat_id", "")),
			"is_bot": bool(p.get("is_bot", false)),
			"is_local": str(p.get("seat_id", "")) == seat_id
		})
	return {
		"players": players_setup,
		"phase": "trump_mode_choice",
		"dealer_seat_id": str(st().get("dealer_seat_id", "")),
		"trump_holder_seat_id": str(st().get("trump_holder_seat_id", "")),
		"dealer_draw_cards": [],
		"server_authoritative": true,
		"is_host": false
	}

func _initialize() -> void:
	_run()

func _run() -> void:
	nm = Node.new()
	nm.name = "TestNetSink"
	root.add_child(nm)
	net = root.get_node_or_null("NetworkManager")
	ok(net != null, "the NetworkManager autoload is available")
	if net == null:
		_report()
		return
	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	# --- a room with two humans and two bots ---
	server._server_create_room({"id": "human_a", "name": "Alice"}, {
		"player_count": 4, "target_score": 15,
		"play_direction": "counter_clockwise", "bots_enabled": true
	}, 2)
	code = str(server.rooms.keys()[0])
	server._server_join_room(code, {"id": "human_b", "name": "Bob"}, false, 3)
	server._server_start_match(code, "human_a", 2)
	await process_frame

	for p in srv_room().get("players", []):
		if str(p.get("id", "")) == "human_a":
			seat_a = str(p.get("seat_id", ""))
		elif str(p.get("id", "")) == "human_b":
			seat_b = str(p.get("seat_id", ""))
	ok(seat_a != "" and seat_b != "" and seat_a != seat_b, "the two humans hold different seats")

	# --- dealer draw: A picks, bots auto-pick, B picks the rest ---
	server._server_claim_dealer_draw_card(code, "human_a", 0, 2)
	await process_frame
	var free_index := -1
	for card in srv_room().get("dealer_draw_cards", []):
		if not bool(card.get("is_claimed", false)):
			free_index = int(card.get("draw_index", -1))
			break
	ok(free_index != -1, "a draw card is left for the second player")
	server._server_claim_dealer_draw_card(code, "human_b", free_index, 3)

	var deadline := Time.get_ticks_msec() + 20000
	while not srv_room().has("match_state") and Time.get_ticks_msec() < deadline:
		await process_frame
	ok(srv_room().has("match_state"), "the match starts after both players pick")
	if not srv_room().has("match_state"):
		_report()
		return

	# --- bring up both clients ---
	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")

	net.pending_match_setup = setup_for(seat_a)
	client_a = packed.instantiate()
	root.add_child(client_a)

	# Client B is deliberately handed client A's setup - the exact corruption
	# a shared user:// file used to cause. It must still end up in its own
	# seat, because the server tells it which seat it is in.
	net.pending_match_setup = setup_for(seat_a)
	client_b = packed.instantiate()
	root.add_child(client_b)
	await process_frame

	client_a._on_snapshot_received(snapshot_for(seat_a))
	await settle(client_a)
	client_b._on_snapshot_received(snapshot_for(seat_b))
	await settle(client_b)

	# --- each client must know its own seat ---
	ok(str(client_a.local_seat_id) == seat_a, "client A knows it is in %s" % seat_a)
	ok(str(client_b.local_seat_id) == seat_b, "client B recovers its own seat (%s) despite a bad handoff" % seat_b)
	ok(str(client_a.local_view_to_abs["my"]) == seat_a, "client A maps its own view to its own seat")
	ok(str(client_b.local_view_to_abs["my"]) == seat_b, "client B maps its own view to its own seat")

	# --- both clients must name the same trump holder ---
	var holder_seat := str(st().get("trump_holder_seat_id", ""))
	var holder_name := str(player_by_seat(holder_seat).get("name", ""))

	var a_shows: String = client_a._display_name(client_a._trump_holder_view())
	var b_shows: String = client_b._display_name(client_b._trump_holder_view())
	var a_expect: String = "You" if seat_a == holder_seat else holder_name
	var b_expect: String = "You" if seat_b == holder_seat else holder_name
	ok(a_shows == a_expect, "client A names the trump holder correctly (shows '%s', expected '%s')" % [a_shows, a_expect])
	ok(b_shows == b_expect, "client B names the trump holder correctly (shows '%s', expected '%s')" % [b_shows, b_expect])

	# --- exactly the right client may act as the trump holder ---
	ok(client_a._is_local_trump_holder() == (seat_a == holder_seat), "client A trump-holder flag matches the server")
	ok(client_b._is_local_trump_holder() == (seat_b == holder_seat), "client B trump-holder flag matches the server")
	var both_holders: bool = client_a._is_local_trump_holder() and client_b._is_local_trump_holder()
	ok(not both_holders, "the two players never both think they choose the trump")

	# --- both clients must name the same dealer ---
	var dealer_seat := str(st().get("dealer_seat_id", ""))
	var dealer_name := str(player_by_seat(dealer_seat).get("name", ""))
	var a_dealer: String = client_a._display_name(client_a.dealer_view)
	var b_dealer: String = client_b._display_name(client_b.dealer_view)
	ok(a_dealer == ("You" if seat_a == dealer_seat else dealer_name), "client A names the dealer correctly (shows '%s')" % a_dealer)
	ok(b_dealer == ("You" if seat_b == dealer_seat else dealer_name), "client B names the dealer correctly (shows '%s')" % b_dealer)

	# --- each client sees its own hand, and only its own ---
	var hand_a: Array = st()["hands"][seat_a]
	var hand_b: Array = st()["hands"][seat_b]
	ok(client_a.hand_cards["my"].size() == hand_a.size(), "client A draws its own hand")
	ok(client_b.hand_cards["my"].size() == hand_b.size(), "client B draws its own hand")

	var a_ids := {}
	for c in client_a.hand_cards["my"]:
		a_ids[str(c.card_id)] = true
	var shares_cards := false
	for c in client_b.hand_cards["my"]:
		if a_ids.has(str(c.card_id)):
			shares_cards = true
	ok(not shares_cards, "the two players never hold the same card")

	# --- the two humans sit on opposite teams with bot partners ---
	ok(str(client_a.my_team) != str(client_b.my_team) or seat_a == seat_b, "each client resolves its own team")

	_report()

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_MULTIPLAYER_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
