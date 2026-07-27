extends SceneTree

# Headless rules check: drives the real Server.gd through complete games and
# asserts the behaviour described in GameRules.txt.

const ServerScript = preload("res://scripts/game/Server.gd")

const RANKS := ["2", "3", "4", "5", "6", "7", "8", "9", "10", "jack", "queen", "king", "ace"]

var server: Node
var nm: Node
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

func wait_until(cond: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return false

func rank_val(r: String) -> int:
	return RANKS.find(r)

func st() -> Dictionary:
	if not server.rooms.has(code):
		return {}
	return server.rooms[code].get("match_state", {})

func room() -> Dictionary:
	return server.rooms.get(code, {})

func _initialize() -> void:
	_run()

func _run() -> void:
	# The server only needs a node at /root/NetworkManager to call rpc_id on.
	# Delivery is irrelevant here: the test inspects server state directly.
	nm = Node.new()
	nm.name = "NetworkManager"
	root.add_child(nm)
	server = ServerScript.new()
	server.name = "test_server"
	root.add_child(server)
	await process_frame

	print("=== deal rules (deterministic) ===")
	deal_unit_check(4, 13, 5, [5, 4, 4])
	deal_unit_check(6, 8, 4, [4, 4])
	deal_unit_check(8, 6, 3, [3, 3])
	print("=== team selection ===")
	team_choice_check()
	print("=== court ends the game immediately ===")
	court_early_end_check()
	print("=== the revealer owes a trump ===")
	reveal_must_play_trump_check()
	print("=== trump only counts from the moment it is revealed ===")
	trump_activation_timing_check()
	print("=== end of match and rematch ===")
	rematch_check()
	print("=== 4-player full match ===")
	await play_match(4)

	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_RULES_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)

func setup_room(player_count: int) -> void:
	server.rooms.clear()
	server._server_create_room({"id": human_id, "name": "Human"}, {
		"player_count": player_count,
		"target_score": 15,
		"play_direction": "counter_clockwise",
		"bots_enabled": true
	}, human_peer)
	code = str(server.rooms.keys()[0])
	server._server_start_match(code, human_id, human_peer)
	await process_frame

func do_dealer_draw(player_count: int) -> void:
	var draws: Array = room().get("dealer_draw_cards", [])
	var ranks := {}
	for d in draws:
		ranks[str(d["rank"])] = true
	ok(draws.size() == player_count, "dealer draw offers one card per player")
	ok(ranks.size() == draws.size(), "dealer draw ranks are unique")
	server._server_claim_dealer_draw_card(code, human_id, 0, human_peer)
	await process_frame
	await process_frame
	# the draw result is held so players can see who won before dealing
	ok(str(room().get("phase", "")) == "dealer_decided", "the finished draw is shown before dealing")
	ok(not room().has("match_state"), "no cards are dealt during the draw reveal")
	await wait_until(func(): return room().has("match_state"), 15000)

func find_human_seat() -> void:
	for p in room().get("players", []):
		if str(p.get("id", "")) == human_id:
			human_seat = str(p.get("seat_id", ""))

func legal_card(hand: Array, lead: String) -> Dictionary:
	if lead != "":
		for c in hand:
			if str(c["suit"]) == lead:
				return c
	if hand.size() > 0:
		return hand[0]
	return {}

func offsuit_card(hand: Array, lead: String) -> Dictionary:
	var has_lead := false
	for c in hand:
		if str(c["suit"]) == lead:
			has_lead = true
	if not has_lead:
		return {}
	for c in hand:
		if str(c["suit"]) != lead:
			return c
	return {}

func play_match(player_count: int) -> void:
	await setup_room(player_count)
	await do_dealer_draw(player_count)
	find_human_seat()

	var s := st()
	ok(not s.is_empty(), "match state created after the dealer draw")
	if s.is_empty():
		return

	var dealer := str(s["dealer_seat_id"])
	var holder := str(s["trump_holder_seat_id"])
	var expected_holder := "seat_%d" % ((int(dealer.trim_prefix("seat_")) + 1) % player_count)
	ok(holder == expected_holder, "trump holder is the player after the dealer")

	# If a bot holds the trump, the server has already run the whole trump
	# setup synchronously by now, so these only apply while it is still paused.
	if str(s["phase"]) == "trump_mode_choice":
		var fb_ok := true
		for seat in s["hands"].keys():
			if (s["hands"][seat] as Array).size() != 5:
				fb_ok = false
		ok(fb_ok, "first batch of 5 for every seat")
		var total_cards := (s["deck"] as Array).size()
		for seat in s["hands"].keys():
			total_cards += (s["hands"][seat] as Array).size()
		ok(total_cards == 52, "4 players use the full 52-card deck")

	if holder == human_seat:
		server._server_choose_trump_mode(code, human_id, "hidden", human_peer)
		await process_frame
		s = st()
		ok(str(s["phase"]) == "closed_trump_card_choice", "closed trump leads to the card choice phase")
		var my_hand: Array = s["hands"][human_seat]
		server._server_receive_game_action(code, human_id, {"type": "confirm_hidden_trump", "card_id": str(my_hand[0]["card_id"])}, human_peer)
		await process_frame
		ok(str(st().get("phase", "")) == "dealing", "the remaining deal runs before play starts")

	# No action may be accepted while the table is still being dealt.
	if str(st().get("phase", "")) == "dealing":
		var dealing_state := st()
		var dealing_seat := str(dealing_state.get("current_turn_seat_id", ""))
		var dealing_hand: Array = dealing_state["hands"][dealing_seat]
		var size_before := dealing_hand.size()
		server._apply_play_card_action(code, dealing_seat, str(dealing_hand[0]["card_id"]))
		ok((st()["hands"][dealing_seat] as Array).size() == size_before, "no card can be played while dealing")

	await wait_until(func(): return str(st().get("phase", "")) == "playing", 25000)

	s = st()
	ok(str(s["phase"]) == "playing", "play begins after the deal completes")
	if str(s["phase"]) != "playing":
		return

	if str(s.get("trump_mode", "")) == "hidden":
		var holder_seat := str(s["hidden_trump"]["holder_seat_id"])
		var holder_snap: Dictionary = server._build_client_snapshot(room(), holder_seat)["game_state"]
		var ht: Dictionary = holder_snap["hidden_trump"]
		ok(str(ht.get("card_id", "")) == "hidden_trump", "hidden trump is redacted even for its holder")
		var real_rank := str(s["hidden_trump"]["rank"])
		ok(str(ht.get("rank", "")) != real_rank or real_rank == "2", "hidden trump rank is not leaked")

	var cards_each := 13
	for seat in s["hands"].keys():
		var expect := cards_each
		if str(s.get("trump_mode", "")) == "hidden" and str(seat) == str(s["hidden_trump"]["holder_seat_id"]):
			expect = cards_each - 1
		ok((s["hands"][seat] as Array).size() == expect, "full hand for " + str(seat))

	var human_snap: Dictionary = server._build_client_snapshot(room(), human_seat)["game_state"]
	var leaked := false
	for view in human_snap["hands"].keys():
		if str(view) == "my":
			continue
		for c in human_snap["hands"][view]:
			if not str(c.get("card_id", "")).begins_with("hidden_"):
				leaked = true
	ok(not leaked, "opponent hands are redacted in snapshots")

	var illegal_tested := false
	var outoforder_tested := false
	var last_seq := 0
	var tricks_seen := 0
	var deadline := Time.get_ticks_msec() + 240000

	while Time.get_ticks_msec() < deadline:
		s = st()
		if s.is_empty():
			break
		var ph := str(s.get("phase", ""))
		if ph == "game_result" or ph == "match_result":
			break
		var lt_poll: Dictionary = s.get("last_trick", {})
		if not lt_poll.is_empty() and int(lt_poll.get("seq", 0)) > last_seq:
			last_seq = int(lt_poll["seq"])
			tricks_seen += 1
			verify_trick_winner(lt_poll, s)

		if ph != "playing" or bool(s.get("resolving", false)) or bool(s.get("revealing_trump", false)):
			await process_frame
			continue
		if str(s.get("current_turn_seat_id", "")) != human_seat:
			await process_frame
			continue

		var hand: Array = s["hands"][human_seat]
		if hand.is_empty():
			await process_frame
			continue
		var lead := str(s.get("lead_suit", ""))

		if not outoforder_tested:
			outoforder_tested = true
			for seat in s["hands"].keys():
				if str(seat) != human_seat and (s["hands"][seat] as Array).size() > 0:
					var before: int = (s["hands"][seat] as Array).size()
					server._apply_play_card_action(code, str(seat), str((s["hands"][seat] as Array)[0]["card_id"]))
					ok((st()["hands"][seat] as Array).size() == before, "out-of-turn play is rejected")
					break

		if not illegal_tested and lead != "":
			var bad := offsuit_card(hand, lead)
			if not bad.is_empty():
				illegal_tested = true
				var before2 := hand.size()
				server._server_receive_game_action(code, human_id, {"type": "play_card", "card_id": str(bad["card_id"])}, human_peer)
				await process_frame
				ok((st()["hands"][human_seat] as Array).size() == before2, "follow-suit violation is rejected")

		s = st()
		if str(s.get("current_turn_seat_id", "")) != human_seat or str(s.get("phase", "")) != "playing":
			continue
		if bool(s.get("resolving", false)) or bool(s.get("revealing_trump", false)):
			continue
		hand = s["hands"][human_seat]
		if hand.is_empty():
			continue
		var pick := legal_card(hand, str(s.get("lead_suit", "")))
		server._server_receive_game_action(code, human_id, {"type": "play_card", "card_id": str(pick["card_id"])}, human_peer)
		await process_frame

		var lt: Dictionary = st().get("last_trick", {})
		if not lt.is_empty() and int(lt.get("seq", 0)) > last_seq:
			last_seq = int(lt["seq"])
			tricks_seen += 1
			verify_trick_winner(lt, st())

	s = st()
	var final_phase := str(s.get("phase", ""))
	ok(final_phase == "game_result" or final_phase == "match_result", "the game reaches a result")
	if s.is_empty():
		return

	var res: Dictionary = s["last_game_result"]
	var total_tricks := int(s["captured_tricks"]["A"]) + int(s["captured_tricks"]["B"])
	var total_tens := int(s["captured_10s"]["A"]) + int(s["captured_10s"]["B"])
	if bool(res.get("ended_early", false)):
		# A court stops the game as soon as the fourth 10 lands, so the
		# remaining tricks are never played.
		ok(total_tricks < cards_each, "a court stops the game before the last trick")
		ok(bool(res.get("court", false)), "only a court can end the game early")
		var cards_left := 0
		for seat in s["hands"].keys():
			cards_left += (s["hands"][seat] as Array).size()
		ok(cards_left > 0, "the early finish leaves the unplayed cards in hand")
	else:
		ok(total_tricks == cards_each, "all 13 tricks are accounted for")
	ok(total_tens == 4, "all four 10s are captured")
	ok(tricks_seen > 0, "trick capture events were published to clients")

	var tens_a := int(s["captured_10s"]["A"])
	var tens_b := int(s["captured_10s"]["B"])
	if tens_a == 4 or tens_b == 4:
		ok(bool(res["court"]) and int(res["points"]) == 5, "a court win scores 5")
	elif tens_a != tens_b:
		ok(int(res["points"]) == 2, "a normal win scores 2")
		var expect_winner := "A" if tens_a > tens_b else "B"
		ok(str(res["winner"]) == expect_winner, "the team with more 10s wins")
	else:
		var tr_a := int(s["captured_tricks"]["A"])
		var tr_b := int(s["captured_tricks"]["B"])
		if tr_a != tr_b:
			var expect_w := "A" if tr_a > tr_b else "B"
			ok(str(res["winner"]) == expect_w, "equal 10s is decided by tricks")

	if str(res.get("winner", "")) != "":
		ok(int(s["scores"][str(res["winner"])]) == int(res["points"]), "the score is updated by the points won")

	if final_phase == "game_result":
		var old_dealer := str(s["dealer_seat_id"])
		var winner_team := str(res.get("winner", ""))
		var dealer_team: String = server._team_for_seat(old_dealer)
		var was_court := bool(res.get("court", false))
		var scores_before: Dictionary = (s["scores"] as Dictionary).duplicate(true)
		await wait_until(func(): return str(st().get("phase", "")) != "game_result", 30000)
		var s2 := st()
		var next_phase := str(s2.get("phase", ""))
		# A bot trump holder makes the server run the trump setup immediately,
		# so the next game may already be past the choice phase.
		var started: bool = next_phase == "trump_mode_choice" or next_phase == "closed_trump_card_choice" or next_phase == "playing"
		ok(started, "the next game starts automatically")
		if started:
			var idx := int(old_dealer.trim_prefix("seat_"))
			var expected := old_dealer
			if winner_team == dealer_team:
				expected = "seat_%d" % ((idx + 1) % player_count)
			elif was_court:
				expected = "seat_%d" % ((idx + 2) % player_count)
			ok(str(s2["dealer_seat_id"]) == expected, "dealer rotation follows the rules")
			var expected_holder2 := "seat_%d" % ((int(expected.trim_prefix("seat_")) + 1) % player_count)
			ok(str(s2["trump_holder_seat_id"]) == expected_holder2, "the new trump holder follows the new dealer")
			ok(int(s2["scores"]["A"]) == int(scores_before["A"]) and int(s2["scores"]["B"]) == int(scores_before["B"]), "scores carry into the next game")
			ok(int(s2["captured_tricks"]["A"]) + int(s2["captured_tricks"]["B"]) <= 1, "captured tricks reset for the next game")
			ok(int(s2["captured_10s"]["A"]) + int(s2["captured_10s"]["B"]) <= 4, "captured 10s reset for the next game")
			var expect_each := 5 if next_phase == "trump_mode_choice" else 13
			var fb_ok := true
			for seat in s2["hands"].keys():
				var h: Array = s2["hands"][seat]
				var allowed: bool = h.size() == expect_each or h.size() == expect_each - 1
				if not allowed:
					fb_ok = false
			ok(fb_ok, "the next game deals a fresh hand to every seat")

func verify_trick_winner(lt: Dictionary, _s: Dictionary) -> void:
	var cards: Array = lt.get("cards", [])
	if cards.is_empty():
		return
	# Trump status is per card, recorded when it was played: revealing the
	# hidden trump mid-trick does not turn cards already on the table into
	# trumps.
	var lead := str(lt.get("lead_suit", str(cards[0]["suit"])))
	ok(lead == str(cards[0]["suit"]), "lead suit matches the first card played")
	var best: Dictionary = cards[0]
	for c in cards:
		var c_trump := bool(c.get("was_trump_at_play_time", false))
		var b_trump := bool(best.get("was_trump_at_play_time", false))
		if c_trump != b_trump:
			if c_trump:
				best = c
		elif c_trump:
			if rank_val(str(c["rank"])) > rank_val(str(best["rank"])):
				best = c
		else:
			var c_lead: bool = str(c["suit"]) == lead
			var b_lead: bool = str(best["suit"]) == lead
			if c_lead and not b_lead:
				best = c
			elif c_lead and b_lead and rank_val(str(c["rank"])) > rank_val(str(best["rank"])):
				best = c
	var expected_seat := str(best["seat_id"])
	var expected_team: String = server._team_for_seat(expected_seat)
	ok(str(lt["winner_seat_id"]) == expected_seat, "trick winner is correct")
	ok(str(lt["team"]) == expected_team, "trick goes to the winner's team")

func seat_of(room_code: String, player_id: String) -> String:
	for p in server.rooms.get(room_code, {}).get("players", []):
		if str(p.get("id", "")) == player_id:
			return str(p.get("seat_id", ""))
	return ""

func team_of(room_code: String, player_id: String) -> String:
	var seat := seat_of(room_code, player_id)
	if seat == "":
		return ""
	return server._team_for_seat(seat)

func team_sizes(room_code: String) -> Array:
	var a := 0
	var b := 0
	for p in server.rooms.get(room_code, {}).get("players", []):
		if team_of(room_code, str(p.get("id", ""))) == "A":
			a += 1
		else:
			b += 1
	return [a, b]

func teams_now(room_code: String) -> Dictionary:
	var out := {}
	for p in server.rooms.get(room_code, {}).get("players", []):
		var pid := str(p.get("id", ""))
		out[pid] = team_of(room_code, pid)
	return out

func moved_count(room_code: String, before: Dictionary) -> int:
	var moved := 0
	for pid in before.keys():
		if team_of(room_code, str(pid)) != str(before[pid]):
			moved += 1
	return moved

func team_choice_check() -> void:
	server.rooms.clear()
	server._server_create_room({"id": "p1", "name": "Alice"}, {
		"player_count": 4, "target_score": 15, "bots_enabled": true
	}, 2)
	var c := str(server.rooms.keys()[0])
	server._server_join_room(c, {"id": "p2", "name": "Bob"}, false, 3)

	ok(team_of(c, "p1") == "A" and team_of(c, "p2") == "B", "without a choice players still alternate seats")

	# A third player joins, then picks a side. Nobody who did not touch the
	# picker may be shuffled across the table by that choice.
	server._server_join_room(c, {"id": "p3", "name": "Cara"}, false, 4)
	var p1_before := team_of(c, "p1")
	var p2_before := team_of(c, "p2")
	server._server_set_team(c, "p3", "B", 4)
	ok(team_of(c, "p3") == "B", "picking a team moves the player onto that team's seats")
	ok(team_of(c, "p1") == p1_before, "the host is not moved by someone else's choice")
	ok(team_of(c, "p2") == p2_before, "a player who never picked is not moved by someone else's choice")
	var distinct := {}
	for p in server.rooms[c].get("players", []):
		distinct[str(p.get("seat_id", ""))] = true
	ok(distinct.size() == server.rooms[c].get("players", []).size(), "two players never share a seat")

	# Team B is now full for a 4-player room. Refusing the request outright
	# meant that once a room filled up nobody could change sides at all, since
	# by then every move is a move into a full side. It becomes a trade.
	var sides_before := team_sizes(c)
	var teams_before := teams_now(c)
	var p1_seat_before := seat_of(c, "p1")
	server._server_set_team(c, "p1", "B", 2)
	ok(team_of(c, "p1") == "B", "asking for a full side trades places rather than being refused")
	ok(seat_of(c, "p1") != p1_seat_before, "the mover really does change seats")
	ok(team_sizes(c) == sides_before, "a trade leaves both sides the same size")
	ok(moved_count(c, teams_before) == 2, "exactly one other player moves in a trade")
	ok(team_of(c, "p2") == "B", "whoever settled on that side first is left where they are")

	# And it works the other way, so a trade can always be undone.
	var sides_mid := team_sizes(c)
	server._server_set_team(c, "p3", "B", 4)
	ok(team_of(c, "p3") == "B", "a player can trade back the other way")
	ok(team_sizes(c) == sides_mid, "and the sides stay balanced")
	var seats_after_trade := {}
	for p in server.rooms[c].get("players", []):
		seats_after_trade[str(p.get("seat_id", ""))] = true
	ok(seats_after_trade.size() == server.rooms[c].get("players", []).size(), "a trade never puts two players on one seat")

	# Someone else's peer may not move a player, trade or not.
	var cara_seat := seat_of(c, "p3")
	server._server_set_team(c, "p3", "A", 2)
	ok(seat_of(c, "p3") == cara_seat, "a team choice from the wrong peer is rejected")

	# Bots fill the remaining seats and the human choices survive the fill.
	var p1_team := team_of(c, "p1")
	var p3_team := team_of(c, "p3")
	server._server_start_match(c, "p1", 2)
	ok(team_of(c, "p1") == p1_team and team_of(c, "p3") == p3_team, "bot fill keeps the chosen teams")
	var seats := {}
	for p in server.rooms[c].get("players", []):
		seats[str(p.get("seat_id", ""))] = true
	ok(seats.size() == 4, "every seat is filled exactly once after the bot fill")
	ok(server.rooms[c].get("players", []).size() == 4, "the bot fill reaches the room size")

	# Seats are locked once the match has started.
	var locked_seat := seat_of(c, "p1")
	server._server_set_team(c, "p1", "B", 2)
	ok(seat_of(c, "p1") == locked_seat, "team choices are refused once the match has started")

	server.rooms.clear()

func court_state(tens_a: int, empty_hands: bool) -> Dictionary:
	var fake_room := {
		"code": "COURT",
		"settings": server._normalize_room_settings({"player_count": 4}),
		"players": server._fill_bots([], 4),
		"dealer_seat_id": "seat_0",
		"trump_holder_seat_id": "seat_1"
	}
	var s: Dictionary = server._create_match_state(fake_room)
	s = server._deal_remaining_cards(s)
	s["phase"] = "playing"
	if empty_hands:
		for seat in s["hands"].keys():
			s["hands"][seat] = []
	s["captured_10s"] = {"A": tens_a, "B": 0}
	s["captured_tricks"] = {"A": 3, "B": 0}
	s["lead_suit"] = "hearts"
	# seat_0 (team A) leads and wins with the ace; the 10 of hearts goes with it.
	s["trick_cards"] = [
		{"seat_id": "seat_0", "card_id": "t_a", "id": 90, "suit": "hearts", "rank": "ace"},
		{"seat_id": "seat_1", "card_id": "t_b", "id": 91, "suit": "hearts", "rank": "10"},
		{"seat_id": "seat_2", "card_id": "t_c", "id": 92, "suit": "hearts", "rank": "4"},
		{"seat_id": "seat_3", "card_id": "t_d", "id": 93, "suit": "hearts", "rank": "5"}
	]
	return s

func cards_in_hands(s: Dictionary) -> int:
	var total := 0
	for h in s.get("hands", {}).values():
		total += (h as Array).size()
	return total

func court_early_end_check() -> void:
	# Three 10s already banked: this trick brings the fourth and must end the
	# game on the spot, even though every seat still holds cards.
	var s := court_state(3, false)
	ok(cards_in_hands(s) > 0, "the court check starts with cards still in hand")
	var out: Dictionary = server._finish_trick_if_needed(s)

	ok(int(out["captured_10s"]["A"]) == 4, "the fourth 10 is credited to the winning team")
	ok(str(out["phase"]) == "game_result", "the game ends the moment a team holds all four 10s")
	var res: Dictionary = out["last_game_result"]
	ok(bool(res.get("court", false)), "the result is a court")
	ok(int(res.get("points", 0)) == 5, "a court scores 5")
	ok(bool(res.get("ended_early", false)), "the result is flagged as an early finish")
	ok(int(out["scores"]["A"]) == 5, "the court points are added to the score")
	ok(cards_in_hands(out) > 0, "unplayed cards are left alone so clients can clear the table")

	# No further play may be accepted once the court has ended the game.
	server.rooms["COURT"] = {
		"code": "COURT",
		"settings": server._normalize_room_settings({"player_count": 4}),
		"players": out["players"],
		"match_state": out
	}
	var seat := str(out.get("current_turn_seat_id", "seat_0"))
	var hand: Array = out["hands"][seat]
	var size_before := hand.size()
	server._apply_play_card_action("COURT", seat, str(hand[0]["card_id"]))
	ok((server.rooms["COURT"]["match_state"]["hands"][seat] as Array).size() == size_before, "no card can be played after a court ends the game")
	server.rooms.erase("COURT")

	# Control: with only two 10s banked, the same trick must not end anything.
	var s2 := court_state(1, false)
	var out2: Dictionary = server._finish_trick_if_needed(s2)
	ok(int(out2["captured_10s"]["A"]) == 2, "a trick with one 10 adds one 10")
	ok(str(out2["phase"]) == "playing", "the game continues while the 10s are still split")
	ok((out2["last_game_result"] as Dictionary).is_empty(), "no result is published mid-game")

	# A court found on the very last trick is not an "early" finish.
	var s3 := court_state(3, true)
	var out3: Dictionary = server._finish_trick_if_needed(s3)
	ok(str(out3["phase"]) == "game_result", "the game still ends when the last trick is played")
	ok(not bool((out3["last_game_result"] as Dictionary).get("ended_early", true)), "a court on the final trick is not flagged early")

func human_players(count: int) -> Array:
	# All-human so no bot timer fires while a deterministic check is running.
	var players: Array = []
	for i in range(count):
		players.append({
			"id": "hp%d" % i, "name": "Player %d" % i, "peer_id": 10 + i,
			"ready": true, "is_bot": false, "is_connected": true,
			"seat_id": "seat_%d" % i, "team_choice": ""
		})
	return players

func reveal_room(revealer_hand: Array) -> Dictionary:
	# seat_1 leads hearts, seat_2 is void in hearts and may open the trump.
	var players := human_players(4)
	var fake_room := {
		"code": "REVEAL",
		"settings": server._normalize_room_settings({"player_count": 4}),
		"players": players,
		"dealer_seat_id": "seat_0",
		"trump_holder_seat_id": "seat_1"
	}
	var s: Dictionary = server._create_match_state(fake_room)
	s = server._deal_remaining_cards(s)
	s["phase"] = "playing"
	s["trump_mode"] = "hidden"
	s["trump_active"] = false
	s["trump_suit"] = ""
	s["hidden_trump"] = {
		"card_id": "ht", "id": 500, "suit": "spades", "rank": "ace",
		"holder_seat_id": "seat_1", "is_set_aside": true,
		"is_revealed": false, "has_returned_to_hand": false
	}
	s["lead_suit"] = "hearts"
	s["current_leader_seat_id"] = "seat_1"
	s["current_turn_seat_id"] = "seat_2"
	s["trick_cards"] = [{"seat_id": "seat_1", "card_id": "lead", "id": 600, "suit": "hearts", "rank": "9"}]
	s["hands"]["seat_2"] = revealer_hand.duplicate(true)
	fake_room["match_state"] = s
	server.rooms["REVEAL"] = fake_room
	return fake_room

func reveal_hand_size() -> int:
	return (server.rooms["REVEAL"]["match_state"]["hands"]["seat_2"] as Array).size()

func clear_reveal_hold() -> void:
	# The server holds the reveal for 3 s before play resumes; skip the wait.
	var room: Dictionary = server.rooms["REVEAL"]
	var s: Dictionary = room["match_state"]
	s["revealing_trump"] = false
	room["match_state"] = s
	server.rooms["REVEAL"] = room

func reveal_must_play_trump_check() -> void:
	# The revealer holds a trump: they must play it and nothing else.
	reveal_room([
		{"card_id": "r_spade", "id": 601, "suit": "spades", "rank": "5"},
		{"card_id": "r_club", "id": 602, "suit": "clubs", "rank": "7"}
	])
	server._apply_hidden_trump_reveal("REVEAL", "seat_2")
	var s: Dictionary = server.rooms["REVEAL"]["match_state"]
	ok(bool(s.get("trump_active", false)) and str(s.get("trump_suit", "")) == "spades", "revealing turns the hidden suit into the trump")
	ok(str(s.get("must_play_trump_seat_id", "")) == "seat_2", "the revealer is marked as owing a trump")

	var snap: Dictionary = server._build_client_snapshot(server.rooms["REVEAL"], "seat_2")["game_state"]
	ok(bool(snap.get("must_play_trump", false)), "the revealer's snapshot says they owe a trump")
	var other: Dictionary = server._build_client_snapshot(server.rooms["REVEAL"], "seat_3")["game_state"]
	ok(not bool(other.get("must_play_trump", false)), "nobody else is told they owe a trump")

	clear_reveal_hold()
	var before := reveal_hand_size()
	server._apply_play_card_action("REVEAL", "seat_2", "r_club")
	ok(reveal_hand_size() == before, "the revealer cannot discard an off-suit card while holding a trump")
	server._apply_play_card_action("REVEAL", "seat_2", "r_spade")
	ok(reveal_hand_size() == before - 1, "the revealer may play their trump")
	ok(str(server.rooms["REVEAL"]["match_state"].get("must_play_trump_seat_id", "")) == "", "the obligation clears once the trump is played")
	server.rooms.erase("REVEAL")

	# The revealer holds no trump: they are free to play anything.
	reveal_room([
		{"card_id": "f_club", "id": 603, "suit": "clubs", "rank": "7"},
		{"card_id": "f_diamond", "id": 604, "suit": "diamonds", "rank": "4"}
	])
	server._apply_hidden_trump_reveal("REVEAL", "seat_2")
	clear_reveal_hold()
	var free_before := reveal_hand_size()
	server._apply_play_card_action("REVEAL", "seat_2", "f_club")
	ok(reveal_hand_size() == free_before - 1, "a revealer with no trump may play any card")
	server.rooms.erase("REVEAL")

	# A bot that reveals owes the same trump.
	reveal_room([
		{"card_id": "b_club", "id": 605, "suit": "clubs", "rank": "7"},
		{"card_id": "b_spade", "id": 606, "suit": "spades", "rank": "3"}
	])
	server._apply_hidden_trump_reveal("REVEAL", "seat_2")
	clear_reveal_hold()
	var bot_state: Dictionary = server.rooms["REVEAL"]["match_state"]
	ok(str(server._choose_bot_card(bot_state, "seat_2")) == "b_spade", "a bot that owes a trump plays its trump")
	server.rooms.erase("REVEAL")

	# Nobody else is constrained: an ordinary void player may still discard.
	reveal_room([
		{"card_id": "o_spade", "id": 607, "suit": "spades", "rank": "5"},
		{"card_id": "o_club", "id": 608, "suit": "clubs", "rank": "7"}
	])
	var room: Dictionary = server.rooms["REVEAL"]
	var plain: Dictionary = room["match_state"]
	plain["trump_active"] = true
	plain["trump_suit"] = "spades"
	room["match_state"] = plain
	server.rooms["REVEAL"] = room
	var plain_before := reveal_hand_size()
	server._apply_play_card_action("REVEAL", "seat_2", "o_club")
	ok(reveal_hand_size() == plain_before - 1, "a void player who did not reveal may still discard off-suit")
	server.rooms.erase("REVEAL")

func trick_of(entries: Array, lead: String) -> Dictionary:
	return {"trick_cards": entries, "lead_suit": lead}

func card_entry(seat: String, suit: String, rank: String, was_trump: bool) -> Dictionary:
	return {
		"seat_id": seat, "card_id": "%s_%s_%s" % [seat, suit, rank], "id": 0,
		"suit": suit, "rank": rank, "was_trump_at_play_time": was_trump
	}

func trump_activation_timing_check() -> void:
	# Hearts led. seat_1 discards the king of diamonds while no trump is
	# active, then seat_2 reveals the hidden trump (diamonds) and plays the 2
	# of diamonds. Only cards played after the reveal are trumps, so the 2
	# beats the king.
	var late_trump := trick_of([
		card_entry("seat_0", "hearts", "9", false),
		card_entry("seat_1", "diamonds", "king", false),
		card_entry("seat_2", "diamonds", "2", true),
		card_entry("seat_3", "hearts", "4", false)
	], "hearts")
	ok(str(server._resolve_trick_winner(late_trump)) == "seat_2", "a trump played after the reveal beats a higher card of the same suit played before it")

	# With no reveal at all, that king of diamonds is just a discard and the
	# highest heart takes the trick.
	var no_trump := trick_of([
		card_entry("seat_0", "hearts", "9", false),
		card_entry("seat_1", "diamonds", "king", false),
		card_entry("seat_2", "diamonds", "2", false),
		card_entry("seat_3", "hearts", "jack", false)
	], "hearts")
	ok(str(server._resolve_trick_winner(no_trump)) == "seat_3", "with no trump active the highest lead suit wins")

	# Two real trumps still compare on rank.
	var two_trumps := trick_of([
		card_entry("seat_0", "hearts", "ace", false),
		card_entry("seat_1", "diamonds", "5", true),
		card_entry("seat_2", "diamonds", "9", true),
		card_entry("seat_3", "hearts", "king", false)
	], "hearts")
	ok(str(server._resolve_trick_winner(two_trumps)) == "seat_2", "the higher of two real trumps wins")

	# An off-suit card that never became a trump cannot win, whatever its rank.
	var junk := trick_of([
		card_entry("seat_0", "hearts", "3", false),
		card_entry("seat_1", "spades", "ace", false),
		card_entry("seat_2", "clubs", "ace", false),
		card_entry("seat_3", "hearts", "4", false)
	], "hearts")
	ok(str(server._resolve_trick_winner(junk)) == "seat_3", "an off-suit ace that is not a trump cannot win")

	# End to end through the real reveal path: the flag has to be stamped on
	# the way in, not just honoured on the way out.
	reveal_room([
		{"card_id": "low_trump", "id": 701, "suit": "spades", "rank": "3"},
		{"card_id": "spare", "id": 702, "suit": "clubs", "rank": "7"}
	])
	var room_state: Dictionary = server.rooms["REVEAL"]["match_state"]
	# seat_1 has already discarded the ace of spades while nothing was trump.
	room_state["trick_cards"] = [
		{"seat_id": "seat_1", "card_id": "lead", "id": 600, "suit": "hearts", "rank": "9", "was_trump_at_play_time": false},
		{"seat_id": "seat_3", "card_id": "early_spade", "id": 703, "suit": "spades", "rank": "ace", "was_trump_at_play_time": false}
	]
	server.rooms["REVEAL"]["match_state"] = room_state
	server._apply_hidden_trump_reveal("REVEAL", "seat_2")
	clear_reveal_hold()
	server._apply_play_card_action("REVEAL", "seat_2", "low_trump")

	var played: Array = server.rooms["REVEAL"]["match_state"]["trick_cards"]
	var mine: Dictionary = {}
	var early: Dictionary = {}
	for entry in played:
		if str(entry.get("card_id", "")) == "low_trump":
			mine = entry
		elif str(entry.get("card_id", "")) == "early_spade":
			early = entry
	ok(not mine.is_empty() and bool(mine.get("was_trump_at_play_time", false)), "a card played after the reveal is stamped as a trump")
	ok(not early.is_empty() and not bool(early.get("was_trump_at_play_time", true)), "a card played before the reveal is not stamped as a trump")
	ok(str(server._resolve_trick_winner(server.rooms["REVEAL"]["match_state"])) == "seat_2", "the 3 of trumps beats the ace played before the reveal")
	server.rooms.erase("REVEAL")

func rematch_check() -> void:
	var players := human_players(4)
	var fake_room := {
		"code": "REMATCH",
		"settings": server._normalize_room_settings({"player_count": 4, "target_score": 15}),
		"players": players,
		"dealer_seat_id": "seat_0",
		"trump_holder_seat_id": "seat_1",
		"phase": "match"
	}
	var s: Dictionary = server._create_match_state(fake_room)
	s["phase"] = "match_result"
	s["scores"] = {"A": 15, "B": 6}
	s["last_game_result"] = {"winner": "A", "court": false, "points": 2, "draw": false, "ended_early": false}
	fake_room["match_state"] = s
	server.rooms["REMATCH"] = fake_room

	# The client needs to know who may offer a rematch.
	var host_snap: Dictionary = server._build_client_snapshot(server.rooms["REMATCH"], "seat_0")["game_state"]
	var guest_snap: Dictionary = server._build_client_snapshot(server.rooms["REMATCH"], "seat_1")["game_state"]
	ok(bool(host_snap.get("is_host", false)), "the host's snapshot says it is the host")
	ok(not bool(guest_snap.get("is_host", true)), "a non-host snapshot does not claim to be the host")
	ok(float(host_snap.get("next_game_delay", 0.0)) > 0.0, "snapshots carry the next-game delay for the countdown")
	ok(float(host_snap.get("turn_time_limit", 0.0)) == server.TURN_DEADLINE_S, "snapshots carry the real turn time limit")

	# players[0] holds peer 10 and is the host; hp1 on peer 11 is not.
	server._server_request_rematch("REMATCH", "hp1", 11)
	ok(str(server.rooms["REMATCH"]["match_state"]["phase"]) == "match_result", "only the host can start a rematch")

	server._server_request_rematch("REMATCH", "hp0", 10)
	var after: Dictionary = server.rooms["REMATCH"]["match_state"]
	ok(int(after["scores"]["A"]) == 0 and int(after["scores"]["B"]) == 0, "a rematch resets the scores")
	ok(str(after["phase"]) != "match_result", "a rematch starts a new game")
	var dealt := true
	for seat in after["hands"].keys():
		if (after["hands"][seat] as Array).is_empty():
			dealt = false
	ok(dealt, "a rematch deals a fresh hand to every seat")
	ok(str(after["dealer_seat_id"]) == "seat_1", "the deal passes on for the rematch")
	ok((after["last_game_result"] as Dictionary).is_empty(), "the rematch clears the old result")
	server.rooms.erase("REMATCH")

func deal_unit_check(player_count: int, cards_each: int, first_batch: int, pattern: Array) -> void:
	# Exercises the dealing rules directly, with no bot timing involved.
	var fake_room := {
		"code": "TEST",
		"settings": server._normalize_room_settings({"player_count": player_count}),
		"players": server._fill_bots([], player_count),
		"dealer_seat_id": "seat_0",
		"trump_holder_seat_id": "seat_1"
	}
	var s: Dictionary = server._create_match_state(fake_room)

	ok(server._get_deal_pattern(player_count) == pattern, "%d players use deal pattern %s" % [player_count, str(pattern)])
	ok(s["hands"].size() == player_count, "%d seats are dealt" % player_count)

	var total := (s["deck"] as Array).size()
	var fb_ok := true
	var has_two := false
	for seat in s["hands"].keys():
		var h: Array = s["hands"][seat]
		total += h.size()
		if h.size() != first_batch:
			fb_ok = false
		for c in h:
			if str(c["rank"]) == "2":
				has_two = true
	for c in s["deck"]:
		if str(c["rank"]) == "2":
			has_two = true

	ok(total == (52 if player_count == 4 else 48), "%d players use a %d-card deck" % [player_count, 52 if player_count == 4 else 48])
	ok(fb_ok, "%d players get a first batch of %d" % [player_count, first_batch])
	if player_count == 4:
		ok(has_two, "4 players keep the 2s")
	else:
		ok(not has_two, "the 2s are removed for %d players" % player_count)
	ok(str(s["phase"]) == "trump_mode_choice", "%d players: deal pauses for the trump choice" % player_count)

	# The first served player must be the one after the dealer.
	var order: Array = server._deal_seat_order("seat_0", player_count, "counter_clockwise")
	ok(str(order[0]) == "seat_1", "%d players: dealing starts after the dealer" % player_count)
	ok(order.size() == player_count, "%d players: every seat is served" % player_count)

	var s2: Dictionary = server._deal_remaining_cards(s)
	var full_ok := true
	for seat in s2["hands"].keys():
		if (s2["hands"][seat] as Array).size() != cards_each:
			full_ok = false
	ok(full_ok, "%d players hold %d cards after the full deal" % [player_count, cards_each])
	ok((s2["deck"] as Array).size() == 0, "%d players: the deck is fully dealt" % player_count)
	ok(str(s2["phase"]) == "dealing", "%d players: the final batch enters the dealing phase" % player_count)

