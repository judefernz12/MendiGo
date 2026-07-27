extends SceneTree

# Drives the real game scene through the whole closed-trump life cycle with
# hand-built snapshots, so the sequence is deterministic instead of waiting for
# a void hand to turn up in a real game.
#
# The key check is card identity: the card that flies back to the hand after a
# reveal must be the very node that was sitting in the trump slot. If the
# renderer deals a fresh one out of the deck instead, that is the stray card
# that used to come flying in from the middle of the table.

var ui: Node
var net: Node
var slot_node_id: int = 0
var fails: Array = []
var checks := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		fails.append(label)
		print("  FAIL: ", label)

func settle() -> void:
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while ui.is_rendering and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

func my_card_ids() -> Array:
	var out: Array = []
	for card in ui.hand_cards["my"]:
		out.append(str(card.card_id))
	return out

func card_named(card_id: String) -> Node3D:
	for card in ui.hand_cards["my"]:
		if str(card.card_id) == card_id:
			return card
	return null

func hidden_hand(seat: String, count: int) -> Array:
	var out: Array = []
	for i in range(count):
		out.append({"card_id": "hidden_%s_%d" % [seat, i], "id": 0, "suit": "clubs", "rank": "2", "is_face_up": false})
	return out

func base_snapshot() -> Dictionary:
	return {
		"phase": "playing", "player_count": 4, "play_direction": "counter_clockwise",
		"target_score": 15, "room_code": "TRUMP",
		"seat_info": {
			"my": {"name": "Me", "is_bot": false, "is_connected": true, "seat_id": "seat_0", "team": "A"},
			"right": {"name": "B1", "is_bot": true, "is_connected": true, "seat_id": "seat_1", "team": "B"},
			"top": {"name": "B2", "is_bot": true, "is_connected": true, "seat_id": "seat_2", "team": "A"},
			"left": {"name": "B3", "is_bot": true, "is_connected": true, "seat_id": "seat_3", "team": "B"}
		},
		"dealer_seat": "left", "dealer_seat_id": "seat_3",
		"hidden_trump_holder_seat": "my", "trump_holder_seat_id": "seat_0",
		"current_leader_index": 0, "current_turn_index": 0, "current_lead_suit": "",
		"trick_in_progress": true, "trick_is_resolving": false,
		"trump_mode": "hidden", "trump_active": false, "trump_suit": "",
		"hidden_trump_revealed": false, "awaiting_hidden_trump_play": false,
		"must_play_trump": false, "revealing_trump": false,
		"deal_order": ["my", "right", "top", "left"], "last_trick": {},
		"trick_seq": 0, "deal_seq": 2,
		"team_a_trick_count": 0, "team_b_trick_count": 0,
		"captured_10s": {"A": 0, "B": 0}, "captured_ten_cards": {"A": [], "B": []},
		"scores": {"A": 0, "B": 0}, "last_game_result": {},
		"hands": {
			"my": [], "right": hidden_hand("seat_1", 3),
			"top": hidden_hand("seat_2", 3), "left": hidden_hand("seat_3", 3)
		},
		"trick_cards": []
	}

func plain_cards() -> Array:
	return [
		{"card_id": "c_a", "id": 1, "suit": "hearts", "rank": "9"},
		{"card_id": "c_b", "id": 2, "suit": "hearts", "rank": "4"},
		{"card_id": "c_c", "id": 3, "suit": "diamonds", "rank": "king"}
	]

func trump_card() -> Dictionary:
	return {"card_id": "c_trump", "id": 4, "suit": "spades", "rank": "ace"}

func redacted_trump() -> Dictionary:
	return {
		"card_id": "hidden_trump", "id": 0, "suit": "clubs", "rank": "2",
		"holder_seat": "my", "holder_seat_id": "seat_0",
		"is_set_aside": true, "is_revealed": false, "has_returned_to_hand": false
	}

func push(snapshot: Dictionary) -> void:
	ui._on_snapshot_received({"game_state": snapshot})
	await settle()

func _initialize() -> void:
	_run()

func _run() -> void:
	net = root.get_node_or_null("NetworkManager")
	ok(net != null, "the NetworkManager autoload is available")
	if net == null:
		_report()
		return

	net.pending_match_setup = {
		"players": [
			{"id": "me", "name": "Me", "seat_id": "seat_0", "is_bot": false, "is_local": true},
			{"id": "b1", "name": "B1", "seat_id": "seat_1", "is_bot": true, "is_local": false},
			{"id": "b2", "name": "B2", "seat_id": "seat_2", "is_bot": true, "is_local": false},
			{"id": "b3", "name": "B3", "seat_id": "seat_3", "is_bot": true, "is_local": false}
		],
		"phase": "playing", "dealer_seat_id": "seat_3", "trump_holder_seat_id": "seat_0",
		"dealer_draw_cards": [], "server_authoritative": true, "is_host": false
	}
	net.latest_game_state_snapshot = {}

	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")
	ui = packed.instantiate()
	root.add_child(ui)
	await process_frame

	# --- 1: a hand that still holds the card that will become the trump ---
	var stage_one := base_snapshot()
	stage_one["hands"]["my"] = plain_cards() + [trump_card()]
	await push(stage_one)
	ok(ui.hand_cards["my"].size() == 4, "the opening hand is drawn")
	ok(my_card_ids().has("c_trump"), "the future trump starts in the hand")

	# --- 2: the card is set aside as the closed trump ---
	var stage_two := base_snapshot()
	stage_two["hands"]["my"] = plain_cards()
	stage_two["hidden_trump"] = redacted_trump()
	await push(stage_two)

	ok(ui.hidden_trump_node != null and is_instance_valid(ui.hidden_trump_node), "the trump card moves to its slot")
	if ui.hidden_trump_node == null:
		_report()
		return
	ok(not ui.hidden_trump_node.is_face_up, "the set-aside trump stays face down")
	ok(ui.hand_cards["my"].size() == 3, "the hidden card leaves the hand")
	ok(not my_card_ids().has("c_trump"), "the hidden card is the one that left")
	slot_node_id = ui.hidden_trump_node.get_instance_id()

	var slot_position: Vector3 = ui.hidden_trump_slot.position
	ok(ui.hidden_trump_node.position.distance_to(slot_position) < 0.05, "the trump card ends up in the trump slot")

	# --- 3: someone opens the trump; it flips face up in the slot ---
	var stage_three := base_snapshot()
	stage_three["hands"]["my"] = plain_cards()
	stage_three["trump_active"] = true
	stage_three["trump_suit"] = "spades"
	stage_three["revealing_trump"] = true
	stage_three["hidden_trump_revealed"] = true
	var revealed := trump_card()
	revealed["holder_seat"] = "my"
	revealed["holder_seat_id"] = "seat_0"
	revealed["is_set_aside"] = true
	revealed["is_revealed"] = true
	revealed["has_returned_to_hand"] = false
	stage_three["hidden_trump"] = revealed
	await push(stage_three)

	ok(ui.hidden_trump_node != null and is_instance_valid(ui.hidden_trump_node), "the trump card is still in its slot while revealing")
	if ui.hidden_trump_node != null:
		ok(ui.hidden_trump_node.get_instance_id() == slot_node_id, "the revealed card is the same card, not a new one")
		ok(ui.hidden_trump_node.is_face_up, "the revealed trump is turned face up")
		ok(str(ui.hidden_trump_node.suit) == "spades", "the revealed trump shows its real suit")
	ok(ui.trump_active and str(ui.trump_suit) == "spades", "the client picks up the active trump")

	# The trump chip has to actually show something once the suit is known.
	ok(ui.trump_panel != null and ui.trump_panel.visible, "the trump chip is on screen")
	ok(str(ui.trump_label.text) == "Spades", "the trump chip names the suit (got '%s')" % str(ui.trump_label.text))
	ok(ui.trump_suit_icon.visible, "the trump chip shows its suit icon")
	ok(ui.trump_suit_icon.texture != null, "the trump suit icon has a texture loaded")
	ok(ui.trump_suit_icon.get_parent() == null or ui.trump_suit_icon.get_parent().get_parent() == ui.trump_panel, "the icon lives inside the trump chip")

	# --- 4: the reveal ends and the card goes back to its owner's hand ---
	var stage_four := base_snapshot()
	stage_four["hands"]["my"] = plain_cards() + [trump_card()]
	stage_four["trump_active"] = true
	stage_four["trump_suit"] = "spades"
	stage_four["hidden_trump_revealed"] = true
	stage_four["must_play_trump"] = true
	var returned := trump_card()
	returned["holder_seat"] = "my"
	returned["holder_seat_id"] = "seat_0"
	returned["is_set_aside"] = false
	returned["is_revealed"] = true
	returned["has_returned_to_hand"] = true
	stage_four["hidden_trump"] = returned
	await push(stage_four)

	ok(ui.hidden_trump_node == null, "the trump slot is empty once the card is returned")
	ok(ui.hand_cards["my"].size() == 4, "the hand is back to four cards, with no duplicate dealt")
	var back := card_named("c_trump")
	ok(back != null, "the trump card is back in the hand")
	if back != null:
		ok(back.get_instance_id() == slot_node_id, "the card that returns is the one from the slot, not a fresh one from the deck")
		ok(back.is_face_up, "the returned trump is face up in my hand")
		ok(str(back.suit) == "spades" and str(back.rank) == "ace", "the returned trump keeps its identity")

	var deck_position: Vector3 = ui.deck_point.position
	var from_deck := 0
	for card in ui.hand_cards["my"]:
		if card.position.distance_to(deck_position) < 0.05:
			from_deck += 1
	ok(from_deck == 0, "no card is left sitting at the deck after the return")

	# --- 5: the revealer owes a trump, so only trumps are playable ---
	ok(ui.must_play_trump, "the client knows it owes a trump")
	ok(ui._owes_trump(), "holding a trump means the obligation applies")
	ok(ui._is_legal_play(back), "the trump card is playable")
	var off_suit := card_named("c_a")
	ok(off_suit != null and not ui._is_legal_play(off_suit), "an off-suit card is refused while a trump is owed")

	# With no trump left in hand the obligation cannot bind.
	var stage_five := base_snapshot()
	stage_five["hands"]["my"] = plain_cards()
	stage_five["trump_active"] = true
	stage_five["trump_suit"] = "spades"
	stage_five["hidden_trump_revealed"] = true
	stage_five["must_play_trump"] = true
	stage_five["hidden_trump"] = returned
	await push(stage_five)
	ok(not ui._owes_trump(), "a player with no trump left is not held to the obligation")
	var any_card := card_named("c_a")
	ok(any_card != null and ui._is_legal_play(any_card), "with no trump in hand any card is playable")

	await reveal_button_check()
	await opponent_trump_return_check()
	await table_signposting_check()
	_report()

func fresh_table() -> void:
	if ui != null and is_instance_valid(ui):
		ui.queue_free()
		await process_frame
	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")
	ui = packed.instantiate()
	root.add_child(ui)
	await process_frame

func opponent_trump_return_check() -> void:
	# Same life cycle, but the trump belongs to the seat on the right. The
	# renderer works out how many cards a seat was dealt by comparing hand
	# sizes, so the card leaving and rejoining that hand has to be accounted
	# for - otherwise a duplicate is dealt from the deck in the middle.
	await fresh_table()

	var opening := base_snapshot()
	opening["hands"]["my"] = plain_cards()
	opening["hands"]["right"] = hidden_hand("seat_1", 3)
	opening["hidden_trump_holder_seat"] = "right"
	opening["trump_holder_seat_id"] = "seat_1"
	await push(opening)
	ok(ui.hand_cards["right"].size() == 3, "the right seat starts with three cards")

	var set_aside := base_snapshot()
	set_aside["hands"]["my"] = plain_cards()
	set_aside["hands"]["right"] = hidden_hand("seat_1", 2)
	set_aside["hidden_trump_holder_seat"] = "right"
	set_aside["trump_holder_seat_id"] = "seat_1"
	var aside := redacted_trump()
	aside["holder_seat"] = "right"
	aside["holder_seat_id"] = "seat_1"
	set_aside["hidden_trump"] = aside
	await push(set_aside)

	ok(ui.hidden_trump_node != null and is_instance_valid(ui.hidden_trump_node), "the opponent's trump moves to the slot")
	if ui.hidden_trump_node == null:
		return
	var slot_id: int = ui.hidden_trump_node.get_instance_id()
	ok(ui.hand_cards["right"].size() == 2, "the opponent's hand drops by one")

	var returned := base_snapshot()
	returned["hands"]["my"] = plain_cards()
	returned["hands"]["right"] = hidden_hand("seat_1", 3)
	returned["hidden_trump_holder_seat"] = "right"
	returned["trump_holder_seat_id"] = "seat_1"
	returned["trump_active"] = true
	returned["trump_suit"] = "spades"
	returned["hidden_trump_revealed"] = true
	var back_home := trump_card()
	back_home["holder_seat"] = "right"
	back_home["holder_seat_id"] = "seat_1"
	back_home["is_set_aside"] = false
	back_home["is_revealed"] = true
	back_home["has_returned_to_hand"] = true
	returned["hidden_trump"] = back_home

	# Watch the transition, not just the end state. A duplicate dealt from the
	# deck is culled again by the opponent-stack cap once the dust settles, so
	# by the time rendering finishes the counts look right - but the player has
	# already watched the stray card fly in from the middle of the table.
	var before_children: int = ui.cards_node.get_child_count()
	var peak := before_children
	ui._on_snapshot_received({"game_state": returned})
	var watch_deadline := Time.get_ticks_msec() + 15000
	while ui.is_rendering and Time.get_ticks_msec() < watch_deadline:
		peak = maxi(peak, ui.cards_node.get_child_count())
		await process_frame
	await settle()
	ok(peak <= before_children, "no extra card is created while the trump returns (peaked at %d cards, started with %d)" % [peak, before_children])

	ok(ui.hidden_trump_node == null, "the slot empties when the opponent takes the card back")
	ok(ui.hand_cards["right"].size() == 3, "the opponent's hand is back to three, with no duplicate")
	var kept := false
	for card in ui.hand_cards["right"]:
		if card.get_instance_id() == slot_id:
			kept = true
	ok(kept, "the card the opponent takes back is the one from the slot")

	var deck_position: Vector3 = ui.deck_point.position
	var stragglers := 0
	for view in ui.seat_order:
		for card in ui.hand_cards[view]:
			if card.position.distance_to(deck_position) < 0.4:
				stragglers += 1
	ok(stragglers == 0, "no second card is dealt out of the middle of the table (%d found)" % stragglers)

func table_signposting_check() -> void:
	# Team colours, the turn highlight, the per-seat timer, the between-games
	# countdown and the end-of-match screen.
	await fresh_table()

	var snapshot := base_snapshot()
	snapshot["hands"]["my"] = plain_cards()
	snapshot["current_turn_index"] = 1
	snapshot["is_host"] = true
	await push(snapshot)
	await process_frame
	await process_frame

	ok(str(ui.my_team) == "A", "the local player resolves its own team")
	ok(ui._is_my_team("top"), "the seat opposite is on my team")
	ok(not ui._is_my_team("right") and not ui._is_my_team("left"), "the seats either side are opponents")

	var mine: StyleBoxFlat = ui.nameplate_styles["top"]
	var theirs: StyleBoxFlat = ui.nameplate_styles["left"]
	ok(mine.border_color.b > mine.border_color.r, "a teammate's plate is tinted towards blue")
	ok(theirs.border_color.r > theirs.border_color.b, "an opponent's plate is tinted towards red")

	# Whose turn it is has to be more than a colour change on the text.
	var active: StyleBoxFlat = ui.nameplate_styles["right"]
	ok(active.border_width_top > theirs.border_width_top, "the seat on turn gets a thicker ring")
	ok(active.border_color.r > 0.8 and active.border_color.g > 0.6 and active.border_color.b < 0.6, "the seat on turn is ringed in gold")

	# The countdown ring follows whoever is playing, not only the local seat.
	ok(str(ui.timer_view) == "right", "the turn timer follows the seat on turn")
	ok(ui.turn_timer_widget.visible, "the turn timer is shown for an opponent's turn")
	var plate: Label = ui.nameplates["right"]
	var gap: float = ui.turn_timer_widget.position.distance_to(plate.position)
	ok(gap < 400.0, "the opponent's timer is drawn next to their name (%.0f px away)" % gap)

	snapshot = base_snapshot()
	snapshot["hands"]["my"] = plain_cards()
	snapshot["current_turn_index"] = 0
	await push(snapshot)
	await process_frame
	ok(str(ui.timer_view) == "my", "the timer moves back to me on my turn")

	# --- between games -------------------------------------------------------
	var between := base_snapshot()
	between["hands"]["my"] = plain_cards()
	between["phase"] = "game_result"
	between["next_game_delay"] = 5.0
	between["last_game_result"] = {
		"winner": "A", "court": false, "points": 2, "draw": false, "ended_early": false,
		"captured_10s": {"A": 3, "B": 1}, "captured_tricks": {"A": 8, "B": 5}
	}
	await push(between)
	await process_frame
	ok(ui.next_game_deadline_ms > 0, "a finished game arms the next-game countdown")
	ok(ui.countdown_panel.visible, "the countdown is shown between games")
	ok(str(ui.countdown_label.text).contains("NEXT GAME IN"), "the countdown says what it is counting to (got '%s')" % str(ui.countdown_label.text))
	ok(not ui.timer_active, "the turn timer stops between games")
	await create_timer(0.4).timeout
	ok(not ui.turn_timer_widget.visible, "the turn timer fades out between games")

	# --- end of match --------------------------------------------------------
	var over := base_snapshot()
	over["hands"]["my"] = plain_cards()
	over["phase"] = "match_result"
	over["is_host"] = true
	over["scores"] = {"A": 15, "B": 6}
	over["last_game_result"] = {
		"winner": "A", "court": false, "points": 2, "draw": false, "ended_early": false,
		"captured_10s": {"A": 3, "B": 1}, "captured_tricks": {"A": 8, "B": 5}
	}
	await push(over)
	await process_frame

	ok(ui.match_over_layer != null and is_instance_valid(ui.match_over_layer), "the end of the match raises a screen instead of nothing happening")
	if ui.match_over_layer == null:
		return
	ok(ui.match_over_layer.find_child("MatchOverBox", true, false) != null, "the match-over screen has its banner")
	ok(ui.match_over_layer.find_child("PlayAgainButton", true, false) != null, "the host is offered a rematch")
	ok(ui.match_over_layer.find_child("MatchOverLeaveButton", true, false) != null, "there is a way back to the menu")
	ok(not ui.countdown_panel.visible, "no next-game countdown runs once the match is over")

	# A non-host must not be offered the rematch button.
	await fresh_table()
	var guest := over.duplicate(true)
	guest["is_host"] = false
	await push(guest)
	await process_frame
	ok(ui.match_over_layer != null, "a non-host also sees the match-over screen")
	if ui.match_over_layer != null:
		ok(ui.match_over_layer.find_child("PlayAgainButton", true, false) == null, "a non-host is not offered the rematch button")
		ok(ui.match_over_layer.find_child("MatchOverLeaveButton", true, false) != null, "a non-host can still leave")

	# Starting the next match clears the screen again.
	var restarted := base_snapshot()
	restarted["hands"]["my"] = plain_cards()
	await push(restarted)
	await process_frame
	ok(ui.match_over_layer == null, "the match-over screen clears when a new match starts")

func reveal_button_check() -> void:
	# A fresh table: my turn, void in the lead suit, closed trump still hidden.
	# The Reveal Trump button has to be offered straight away - it used to stay
	# hidden until some unrelated UI event (tapping a card) refreshed the HUD.
	ui.queue_free()
	await process_frame

	var packed: PackedScene = load("res://scenes/game/GameRoom3D.tscn")
	ui = packed.instantiate()
	root.add_child(ui)
	await process_frame

	var snapshot := base_snapshot()
	snapshot["hands"]["my"] = [
		{"card_id": "v_a", "id": 11, "suit": "clubs", "rank": "9"},
		{"card_id": "v_b", "id": 12, "suit": "diamonds", "rank": "4"}
	]
	snapshot["hands"]["right"] = hidden_hand("seat_1", 2)
	snapshot["hands"]["top"] = hidden_hand("seat_2", 2)
	snapshot["hands"]["left"] = hidden_hand("seat_3", 2)
	snapshot["current_lead_suit"] = "hearts"
	snapshot["current_turn_index"] = 0
	snapshot["current_leader_index"] = 1
	snapshot["hidden_trump"] = redacted_trump()
	snapshot["trick_cards"] = [{"seat": "right", "seat_id": "seat_1", "card_id": "x1", "id": 21, "suit": "hearts", "rank": "9"}]
	await push(snapshot)

	ok(ui.selected_card == null, "no card is selected yet")
	ok(ui.my_turn and not ui.table_busy, "it is my turn and the table is idle")
	ok(ui.open_trump_button.visible, "Reveal Trump is offered immediately, with no card selected")
	ok(not ui.open_trump_button.disabled, "Reveal Trump is enabled")
	ok(ui.play_button.disabled, "Play stays disabled until a card is picked")

	# Following suit is possible again: the offer must disappear.
	var followable := base_snapshot()
	followable["hands"]["my"] = [{"card_id": "h_a", "id": 13, "suit": "hearts", "rank": "9"}]
	followable["hands"]["right"] = hidden_hand("seat_1", 2)
	followable["hands"]["top"] = hidden_hand("seat_2", 2)
	followable["hands"]["left"] = hidden_hand("seat_3", 2)
	followable["current_lead_suit"] = "hearts"
	followable["current_turn_index"] = 0
	followable["current_leader_index"] = 1
	followable["hidden_trump"] = redacted_trump()
	followable["trick_cards"] = [{"seat": "right", "seat_id": "seat_1", "card_id": "x1", "id": 21, "suit": "hearts", "rank": "9"}]
	await push(followable)
	ok(not ui.open_trump_button.visible, "Reveal Trump is withdrawn when the lead suit can be followed")

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_TRUMP_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
