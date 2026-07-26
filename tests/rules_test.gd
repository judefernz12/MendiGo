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
	# Use the trump state the server recorded for this trick, not the current
	# one: a later trick can activate a different trump.
	var lead := str(lt.get("lead_suit", str(cards[0]["suit"])))
	var trump := str(lt.get("trump_suit", ""))
	var trump_on := bool(lt.get("trump_active", false))
	ok(lead == str(cards[0]["suit"]), "lead suit matches the first card played")
	var best: Dictionary = cards[0]
	for c in cards:
		var c_trump: bool = trump_on and str(c["suit"]) == trump
		var b_trump: bool = trump_on and str(best["suit"]) == trump
		if c_trump and not b_trump:
			best = c
		elif c_trump == b_trump:
			if str(c["suit"]) == str(best["suit"]) and rank_val(str(c["rank"])) > rank_val(str(best["rank"])):
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

	# Team B is now full for a 4-player room, so p1 cannot join it.
	var before := seat_of(c, "p1")
	server._server_set_team(c, "p1", "B", 2)
	ok(team_of(c, "p1") == "A", "a full team refuses another player")
	ok(seat_of(c, "p1") == before, "a refused team choice does not move the player")

	# Cara goes back to A, which frees a B seat for p1.
	server._server_set_team(c, "p3", "A", 4)
	ok(team_of(c, "p3") == "A", "a player can switch back")
	server._server_set_team(c, "p1", "B", 2)
	ok(team_of(c, "p1") == "B", "the seat freed by a switch becomes available")

	# Someone else's peer may not move a player.
	var cara_seat := seat_of(c, "p3")
	server._server_set_team(c, "p3", "B", 2)
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

