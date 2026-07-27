extends Node

const PORT := 12345
const MAX_CLIENTS := 64
const ROOM_SIZE := 4
const VALID_PLAYER_COUNTS := [4, 6, 8]
const RANKS_HIGH_TO_LOW := ["ace", "king", "queen", "jack", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
const RANKS_LOW_TO_HIGH := ["2", "3", "4", "5", "6", "7", "8", "9", "10", "jack", "queen", "king", "ace"]
const SUITS := ["clubs", "diamonds", "hearts", "spades"]
const TARGET_SCORE := 15
const TURN_DEADLINE_S := 20.0
const CHOICE_DEADLINE_S := 25.0
const TRICK_RESOLVE_PAUSE_S := 1.6
const BOT_PLAY_DELAY_S := 1.1
const NEXT_GAME_DELAY_S := 5.0
const TRUMP_REVEAL_HOLD_S := 3.0
const BOT_CHOICE_DELAY_S := 2.5
const DEALER_REVEAL_HOLD_S := 3.0
const DEAL_ANIMATION_HOLD_S := 2.5
# A court gets a longer hold so clients can play the celebration.
const COURT_RESULT_DELAY_S := 9.0

# Every deck (52 or 48 cards) contains exactly four 10s. Once one team holds
# all of them the court is locked in and nothing later can change the result.
const TENS_IN_DECK := 4

var rooms: Dictionary = {}
var peer_to_room: Dictionary = {}

func _network_manager() -> Node:
	return get_node("/root/NetworkManager")

func _ready() -> void:
	print("Starting MendiGo server...")

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT, "*")
	if err != OK:
		push_error("Could not start WebSocket server on port %d. Error: %s" % [PORT, err])
		return

	multiplayer.multiplayer_peer = peer
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("WebSocket server running on port %d" % PORT)

func _on_peer_disconnected(peer_id: int) -> void:
	if not peer_to_room.has(peer_id):
		return

	var code: String = str(peer_to_room[peer_id])
	peer_to_room.erase(peer_id)

	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var players: Array = room.get("players", [])
	for i in range(players.size()):
		var p: Dictionary = players[i]
		if int(p.get("peer_id", -1)) == peer_id:
			p["is_connected"] = false
			p["peer_id"] = -1
			players[i] = p

	var spectators: Array = room.get("spectators", [])
	for i in range(spectators.size() - 1, -1, -1):
		var s: Dictionary = spectators[i]
		if int(s.get("peer_id", -1)) == peer_id:
			spectators.remove_at(i)

	var has_human := false
	for p_raw in players:
		var p: Dictionary = p_raw
		if not bool(p.get("is_bot", false)):
			has_human = true
			break

	if not has_human and spectators.is_empty():
		rooms.erase(code)
		return

	room["players"] = players
	room["spectators"] = spectators
	rooms[code] = room
	_broadcast_lobby(code)

func _generate_room_code() -> String:
	const CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	while true:
		var code := ""
		for i in range(5):
			code += CHARS[randi() % CHARS.length()]
		if not rooms.has(code):
			return code
	return "ROOM1"

func _normalize_player(player: Dictionary, peer_id: int) -> Dictionary:
	return {
		"id": str(player.get("id", "")),
		"name": str(player.get("name", "Player")),
		"peer_id": peer_id,
		"ready": false,
		"is_bot": false,
		"is_connected": true,
		"seat_id": "",
		"team_choice": ""
	}

func _normalize_room_settings(raw_settings: Dictionary) -> Dictionary:
	var player_count := int(raw_settings.get("player_count", 4))
	if not VALID_PLAYER_COUNTS.has(player_count):
		player_count = 4

	var target_score := int(raw_settings.get("target_score", TARGET_SCORE))
	if target_score <= 0:
		target_score = TARGET_SCORE

	var play_direction := str(raw_settings.get("play_direction", "counter_clockwise"))
	if play_direction != "clockwise" and play_direction != "counter_clockwise":
		play_direction = "counter_clockwise"

	return {
		"player_count": player_count,
		"target_score": target_score,
		"play_direction": play_direction,
		"private_room": bool(raw_settings.get("private_room", true)),
		"bots_enabled": bool(raw_settings.get("bots_enabled", true)),
		"spectators_enabled": bool(raw_settings.get("spectators_enabled", true))
	}

func _team_for_seat_index(seat_index: int) -> String:
	return "A" if seat_index % 2 == 0 else "B"

func _team_capacity(player_count: int) -> int:
	# Teams alternate around the table, so each side owns half the seats.
	return int(player_count / 2)

func _team_choice_count(players: Array, team: String, skip_player_id: String = "") -> int:
	var count := 0
	for p_raw in players:
		var p: Dictionary = p_raw
		if str(p.get("id", "")) == skip_player_id:
			continue
		if str(p.get("team_choice", "")) == team:
			count += 1
	return count

func _assign_seats(players: Array, player_count: int = -1) -> Array:
	# Teams are still alternating seats (GameRules.txt), so honouring a team
	# choice means handing that player a seat of the matching parity. Players
	# who picked nothing fill whatever is left, in join order, which reproduces
	# the old behaviour exactly when nobody has chosen.
	var seats := player_count
	if seats <= 0:
		seats = players.size()
	seats = maxi(seats, players.size())

	var seat_owner := {}    # seat index -> player index
	var player_seat := {}   # player index -> seat index

	for i in range(players.size()):
		var p: Dictionary = players[i]
		var choice := str(p.get("team_choice", ""))
		if choice != "A" and choice != "B":
			continue
		for s in range(seats):
			if seat_owner.has(s):
				continue
			if _team_for_seat_index(s) != choice:
				continue
			seat_owner[s] = i
			player_seat[i] = s
			break

	for i in range(players.size()):
		if player_seat.has(i):
			continue
		for s in range(seats):
			if seat_owner.has(s):
				continue
			seat_owner[s] = i
			player_seat[i] = s
			break

	for i in range(players.size()):
		var p: Dictionary = players[i]
		p["seat_id"] = "seat_%d" % int(player_seat.get(i, i))
		players[i] = p
	return players

func _lock_team_choices(players: Array) -> Array:
	# A human who never touched the team picker still owns the side they were
	# seated on, so record it. Without this, the next player to pick a team
	# could silently push them across the table.
	for i in range(players.size()):
		var p: Dictionary = players[i]
		if bool(p.get("is_bot", false)):
			continue
		if str(p.get("team_choice", "")) != "":
			continue
		var seat_id := str(p.get("seat_id", ""))
		if not seat_id.begins_with("seat_"):
			continue
		p["team_choice"] = _team_for_seat_index(int(seat_id.trim_prefix("seat_")))
		players[i] = p
	return players

func _get_room_host_peer(room: Dictionary) -> int:
	var players: Array = room.get("players", [])
	if players.is_empty():
		return -1
	return int(players[0].get("peer_id", -1))

func _find_player_index(players: Array, player_id: String) -> int:
	for i in range(players.size()):
		var p: Dictionary = players[i]
		if str(p.get("id", "")) == player_id:
			return i
	return -1

func _find_player_by_id(players: Array, player_id: String) -> Dictionary:
	var index := _find_player_index(players, player_id)
	if index == -1:
		return {}
	return players[index]

func _is_sender_for_player(player: Dictionary, sender_peer_id: int) -> bool:
	if bool(player.get("is_bot", false)):
		return false
	var expected_peer_id := int(player.get("peer_id", -1))
	if sender_peer_id == 0:
		sender_peer_id = multiplayer.get_remote_sender_id()
	return expected_peer_id == sender_peer_id

func _broadcast_lobby(code: String) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var players: Array = room.get("players", [])
	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	for p_raw in players:
		var p: Dictionary = p_raw
		if bool(p.get("is_bot", false)):
			continue
		_network_manager().rpc_id(int(p.get("peer_id", -1)), "_client_lobby_updated", players, settings)

func _fill_bots(players: Array, player_count: int) -> Array:
	# Bots are appended last and never pick a team, so they take whatever seats
	# the humans left over - which keeps both sides full.
	var filled := players.duplicate(true)
	while filled.size() < player_count:
		var bot_index := filled.size() + 1
		filled.append({
			"id": "bot_%d" % bot_index,
			"name": "Bot %d" % bot_index,
			"peer_id": 0,
			"ready": true,
			"is_bot": true,
			"is_connected": true,
			"seat_id": "",
			"team_choice": ""
		})
	return _assign_seats(filled, player_count)

func _create_dealer_draw_cards(player_count: int) -> Array:
	var ranks := RANKS_HIGH_TO_LOW.duplicate()
	ranks.shuffle()
	var cards: Array = []
	for i in range(player_count):
		cards.append({
			"draw_index": i,
			"suit": SUITS[randi() % SUITS.size()],
			"rank": ranks[i],
			"is_claimed": false,
			"claimed_by_player_id": "",
			"claimed_by_seat_id": ""
		})
	return cards

func _rank_value(rank: String) -> int:
	var idx := RANKS_LOW_TO_HIGH.find(rank)
	if idx == -1:
		return -1
	return idx

func _create_deck(player_count: int) -> Array:
	var deck: Array = []
	var next_id := 0
	for suit in SUITS:
		for rank in RANKS_LOW_TO_HIGH:
			if player_count != 4 and rank == "2":
				continue
			deck.append({
				"card_id": "card_%d" % next_id,
				"id": next_id,
				"suit": suit,
				"rank": rank
			})
			next_id += 1
	deck.shuffle()
	return deck

func _team_for_seat(seat_id: String) -> String:
	var seat_index := int(seat_id.trim_prefix("seat_"))
	return "A" if seat_index % 2 == 0 else "B"

func _next_seat(seat_id: String, player_count: int = ROOM_SIZE, play_direction: String = "counter_clockwise") -> String:
	var seat_index := int(seat_id.trim_prefix("seat_"))
	var step := 1 if play_direction == "counter_clockwise" else -1
	return "seat_%d" % ((seat_index + step + player_count) % player_count)

func _get_deal_pattern(player_count: int) -> Array:
	match player_count:
		4:
			return [5, 4, 4]
		6:
			return [4, 4]
		8:
			return [3, 3]
		_:
			return [5, 4, 4]

func _create_match_state(room: Dictionary) -> Dictionary:
	var players: Array = room.get("players", [])
	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	var player_count := int(settings.get("player_count", 4))
	var deal_pattern := _get_deal_pattern(player_count)
	var deck := _create_deck(player_count)
	var hands := {}
	for p_raw in players:
		var p: Dictionary = p_raw
		hands[str(p.get("seat_id", ""))] = []

	# Deal in play direction starting with the player after the dealer (the
	# trump holder), in batches, exactly as GameRules.txt describes.
	var deal_order := _deal_seat_order(
		str(room.get("dealer_seat_id", "seat_0")),
		player_count,
		str(settings.get("play_direction", "counter_clockwise"))
	)
	var first_batch_size := int(deal_pattern[0])
	for seat_id in deal_order:
		for _i in range(first_batch_size):
			if deck.is_empty():
				break
			hands[str(seat_id)].append(deck.pop_back())

	return {
		"room_code": room.get("code", ""),
		"phase": "trump_mode_choice",
		"player_count": player_count,
		"target_score": int(settings.get("target_score", TARGET_SCORE)),
		"play_direction": str(settings.get("play_direction", "counter_clockwise")),
		"players": players,
		"dealer_seat_id": room.get("dealer_seat_id", "seat_0"),
		"trump_holder_seat_id": room.get("trump_holder_seat_id", "seat_1"),
		"trump_mode": "",
		"trump_active": false,
		"trump_suit": "",
		"hidden_trump": {
			"card_id": "",
			"suit": "",
			"rank": "",
			"holder_seat_id": room.get("trump_holder_seat_id", "seat_1"),
			"is_set_aside": false,
			"is_revealed": false,
			"has_returned_to_hand": false
		},
		"deck": deck,
		"hands": hands,
		"trick_cards": [],
		"lead_suit": "",
		"current_turn_seat_id": room.get("trump_holder_seat_id", "seat_1"),
		"current_leader_seat_id": room.get("trump_holder_seat_id", "seat_1"),
		"captured_tricks": {"A": 0, "B": 0},
		"captured_10s": {"A": 0, "B": 0},
		"captured_ten_cards": {"A": [], "B": []},
		"scores": {"A": 0, "B": 0},
		"last_game_result": {},
		"resolving": false,
		"revealing_trump": false,
		"must_play_trump_seat_id": "",
		"trick_seq": 0,
		"last_trick": {},
		"deal_seq": 1
	}

func _deal_seat_order(dealer_seat_id: String, player_count: int, play_direction: String) -> Array:
	var order: Array = []
	var seat_id := dealer_seat_id
	for _i in range(player_count):
		seat_id = _next_seat(seat_id, player_count, play_direction)
		order.append(seat_id)
	return order

func _deal_remaining_cards(state: Dictionary) -> Dictionary:
	var deck: Array = state.get("deck", [])
	var player_count := int(state.get("player_count", 4))
	var deal_pattern := _get_deal_pattern(player_count)
	var deal_order := _deal_seat_order(
		str(state.get("dealer_seat_id", "seat_0")),
		player_count,
		str(state.get("play_direction", "counter_clockwise"))
	)
	for batch_index in range(1, deal_pattern.size()):
		var batch_size := int(deal_pattern[batch_index])
		for seat_id in deal_order:
			for _i in range(batch_size):
				if deck.is_empty():
					break
				state["hands"][str(seat_id)].append(deck.pop_back())
	state["deck"] = deck
	state["deal_seq"] = int(state.get("deal_seq", 0)) + 1
	# "dealing" blocks every action (humans and bots) until the clients have
	# had time to animate the remaining cards; _start_play_after_deal then
	# switches to "playing".
	state["phase"] = "dealing"
	state["current_turn_seat_id"] = state.get("trump_holder_seat_id", "seat_1")
	state["current_leader_seat_id"] = state.get("trump_holder_seat_id", "seat_1")
	return state

func _start_play_after_deal(code: String) -> void:
	await get_tree().create_timer(DEAL_ANIMATION_HOLD_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if str(state.get("phase", "")) != "dealing":
		return
	state["phase"] = "playing"
	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)

func _view_mapping_for_abs_seat(abs_seat_id: String, player_count: int = ROOM_SIZE) -> Dictionary:
	var mapping := {}
	var local_index := int(abs_seat_id.trim_prefix("seat_"))
	var ordered_views := ["my", "right", "top", "left", "seat4", "seat5", "seat6", "seat7"]
	for offset in range(player_count):
		mapping["seat_%d" % ((local_index + offset) % player_count)] = ordered_views[offset]
	return mapping

func _seat_order_for_abs_seat(abs_seat_id: String, player_count: int = ROOM_SIZE) -> Array:
	var local_index := int(abs_seat_id.trim_prefix("seat_"))
	var order: Array = []
	for offset in range(player_count):
		order.append("seat_%d" % ((local_index + offset) % player_count))
	return order

func _deal_order_views(state: Dictionary, mapping: Dictionary) -> Array:
	var order := _deal_seat_order(
		str(state.get("dealer_seat_id", "seat_0")),
		int(state.get("player_count", ROOM_SIZE)),
		str(state.get("play_direction", "counter_clockwise"))
	)
	var views: Array = []
	for seat_id in order:
		var view := str(mapping.get(str(seat_id), ""))
		if view != "":
			views.append(view)
	return views

func _host_seat_id(room: Dictionary) -> String:
	var host_peer := _get_room_host_peer(room)
	if host_peer <= 0:
		return ""
	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		if int(p.get("peer_id", -1)) == host_peer:
			return str(p.get("seat_id", ""))
	return ""

func _build_client_snapshot(room: Dictionary, target_seat_id: String) -> Dictionary:
	var state: Dictionary = room.get("match_state", {}).duplicate(true)
	var player_count := int(state.get("player_count", room.get("settings", {}).get("player_count", 4)))
	var mapping := _view_mapping_for_abs_seat(target_seat_id, player_count)
	var abs_order := _seat_order_for_abs_seat(target_seat_id, player_count)

	# The first batch is dealt face down and the closed trump is chosen blind,
	# so nobody - not even the trump holder - may see their own cards until
	# the trump is settled. Card ids stay real so clients keep card identity.
	var snapshot_phase := str(state.get("phase", ""))
	var hide_own_faces: bool = snapshot_phase == "trump_mode_choice" or snapshot_phase == "closed_trump_card_choice"

	var hands_by_view := {"my": [], "right": [], "top": [], "left": []}
	var source_hands: Dictionary = state.get("hands", {})
	for seat_id in source_hands.keys():
		var view_name := str(mapping.get(str(seat_id), ""))
		if view_name == "":
			continue
		var cards: Array = source_hands[seat_id]
		if str(seat_id) == target_seat_id:
			if hide_own_faces:
				var masked_cards: Array = []
				for card_raw in cards:
					var card: Dictionary = card_raw
					masked_cards.append({
						"card_id": card.get("card_id", ""),
						"id": 0,
						"suit": "clubs",
						"rank": "2",
						"is_face_up": false,
						"face_hidden": true
					})
				hands_by_view[view_name] = masked_cards
			else:
				hands_by_view[view_name] = cards.duplicate(true)
		else:
			var hidden_cards: Array = []
			for i in range(cards.size()):
				hidden_cards.append({
					"card_id": "hidden_%s_%d" % [str(seat_id), i],
					"id": 0,
					"suit": "clubs",
					"rank": "2",
					"is_face_up": false
				})
			hands_by_view[view_name] = hidden_cards

	var trick_by_view: Array = []
	for entry_raw in state.get("trick_cards", []):
		var entry: Dictionary = entry_raw.duplicate(true)
		entry["seat"] = str(mapping.get(str(entry.get("seat_id", "")), "my"))
		trick_by_view.append(entry)

	var dealer_view := str(mapping.get(str(state.get("dealer_seat_id", "seat_0")), "my"))
	var holder_view := str(mapping.get(str(state.get("trump_holder_seat_id", "seat_1")), "right"))
	var current_turn_index := abs_order.find(str(state.get("current_turn_seat_id", "seat_0")))
	var leader_index := abs_order.find(str(state.get("current_leader_seat_id", "seat_0")))

	var hidden_trump: Dictionary = state.get("hidden_trump", {}).duplicate(true)
	if bool(hidden_trump.get("is_set_aside", false)) and not bool(hidden_trump.get("is_revealed", false)):
		hidden_trump["card_id"] = "hidden_trump"
		hidden_trump["id"] = 0
		hidden_trump["suit"] = "clubs"
		hidden_trump["rank"] = "2"
	hidden_trump["holder_seat"] = holder_view
	hidden_trump["holder_seat_id"] = state.get("trump_holder_seat_id", "seat_1")

	var seat_info := {}
	for p_raw in state.get("players", []):
		var p: Dictionary = p_raw
		var p_seat_id := str(p.get("seat_id", ""))
		var p_view := str(mapping.get(p_seat_id, ""))
		if p_view == "":
			continue
		seat_info[p_view] = {
			"name": str(p.get("name", "Player")),
			"is_bot": bool(p.get("is_bot", false)),
			"is_connected": bool(p.get("is_connected", true)),
			"seat_id": p_seat_id,
			"team": _team_for_seat(p_seat_id)
		}

	# Remap the completed-trick event into this player's view so the client
	# can animate the cards into the correct captured pile.
	var last_trick: Dictionary = state.get("last_trick", {}).duplicate(true)
	if not last_trick.is_empty():
		var mapped_trick_cards: Array = []
		for entry_raw in last_trick.get("cards", []):
			var entry: Dictionary = entry_raw.duplicate(true)
			entry["seat"] = str(mapping.get(str(entry.get("seat_id", "")), "my"))
			mapped_trick_cards.append(entry)
		last_trick["cards"] = mapped_trick_cards
		last_trick["winner_seat"] = str(mapping.get(str(last_trick.get("winner_seat_id", "")), "my"))

	var client_state := {
		"phase": state.get("phase", "playing"),
		"player_count": player_count,
		"play_direction": state.get("play_direction", "counter_clockwise"),
		"target_score": state.get("target_score", TARGET_SCORE),
		"room_code": state.get("room_code", ""),
		"seat_info": seat_info,
		"dealer_seat": dealer_view,
		"dealer_seat_id": state.get("dealer_seat_id", "seat_0"),
		"hidden_trump_holder_seat": holder_view,
		"trump_holder_seat_id": state.get("trump_holder_seat_id", "seat_1"),
		"current_leader_index": leader_index,
		"current_turn_index": current_turn_index,
		"current_lead_suit": state.get("lead_suit", ""),
		"trick_in_progress": state.get("phase", "") == "playing",
		"trick_is_resolving": bool(state.get("resolving", false)),
		"trump_mode": state.get("trump_mode", ""),
		"trump_active": state.get("trump_active", false),
		"trump_suit": state.get("trump_suit", ""),
		"hidden_trump_revealed": hidden_trump.get("is_revealed", false),
		"awaiting_hidden_trump_play": false,
		"must_play_trump": str(state.get("must_play_trump_seat_id", "")) == target_seat_id,
		"hidden_trump": hidden_trump,
		"revealing_trump": bool(state.get("revealing_trump", false)),
		"deal_order": _deal_order_views(state, mapping),
		"last_trick": last_trick,
		"trick_seq": int(state.get("trick_seq", 0)),
		"deal_seq": int(state.get("deal_seq", 0)),
		"team_a_trick_count": state.get("captured_tricks", {}).get("A", 0),
		"team_b_trick_count": state.get("captured_tricks", {}).get("B", 0),
		"captured_10s": state.get("captured_10s", {"A": 0, "B": 0}),
		"captured_ten_cards": state.get("captured_ten_cards", {"A": [], "B": []}),
		"scores": state.get("scores", {"A": 0, "B": 0}),
		"last_game_result": state.get("last_game_result", {}),
		# How long the client has before the next deal, so it can show an
		# honest countdown instead of guessing.
		"next_game_delay": COURT_RESULT_DELAY_S if bool((state.get("last_game_result", {}) as Dictionary).get("court", false)) else NEXT_GAME_DELAY_S,
		"is_host": _host_seat_id(room) == target_seat_id,
		"turn_time_limit": TURN_DEADLINE_S,
		"hands": hands_by_view,
		"trick_cards": trick_by_view
	}

	return {"game_state": client_state}

func _broadcast_match_state(code: String) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	room = _auto_return_hidden_trump_if_needed(room)
	rooms[code] = room
	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		if bool(p.get("is_bot", false)):
			continue
		var peer_id := int(p.get("peer_id", -1))
		var seat_id := str(p.get("seat_id", ""))
		_network_manager().rpc_id(peer_id, "_client_receive_game_state", _build_client_snapshot(room, seat_id))

	for s_raw in room.get("spectators", []):
		var spectator: Dictionary = s_raw
		var peer_id := int(spectator.get("peer_id", -1))
		if peer_id <= 0:
			continue
		_network_manager().rpc_id(peer_id, "_client_receive_game_state", _build_spectator_snapshot(room))

	_maybe_run_bot_turn(code)
	_maybe_schedule_next_game(code)
	_arm_action_deadline(code)

func _build_spectator_snapshot(room: Dictionary) -> Dictionary:
	var snapshot := _build_client_snapshot(room, "seat_0")
	var client_state: Dictionary = snapshot.get("game_state", {})
	var hands: Dictionary = client_state.get("hands", {})
	for view_name in hands.keys():
		var redacted: Array = []
		var cards: Array = hands[view_name]
		for i in range(cards.size()):
			redacted.append({
				"card_id": "spectator_hidden_%s_%d" % [str(view_name), i],
				"id": 0,
				"suit": "clubs",
				"rank": "2",
				"is_face_up": false
			})
		hands[view_name] = redacted
	client_state["hands"] = hands
	client_state["is_spectator"] = true
	snapshot["game_state"] = client_state
	return snapshot

func _auto_return_hidden_trump_if_needed(room: Dictionary) -> Dictionary:
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return room
	if state.get("trump_mode", "") != "hidden":
		return room

	var hidden_trump: Dictionary = state.get("hidden_trump", {})
	if not bool(hidden_trump.get("is_set_aside", false)):
		return room

	var current_seat := str(state.get("current_turn_seat_id", ""))
	var holder := str(hidden_trump.get("holder_seat_id", ""))
	if current_seat != holder:
		return room

	var holder_hand: Array = state.get("hands", {}).get(holder, [])
	if not holder_hand.is_empty():
		return room

	state["trump_active"] = true
	state["trump_suit"] = str(hidden_trump.get("suit", ""))
	hidden_trump["is_revealed"] = true
	hidden_trump["is_set_aside"] = false
	hidden_trump["has_returned_to_hand"] = true
	state["hidden_trump"] = hidden_trump
	state["hands"][holder].append({
		"card_id": hidden_trump.get("card_id", ""),
		"id": hidden_trump.get("id", 0),
		"suit": hidden_trump.get("suit", ""),
		"rank": hidden_trump.get("rank", "")
	})
	room["match_state"] = state
	return room

func _find_card_index(hand: Array, card_id: String) -> int:
	for i in range(hand.size()):
		var card: Dictionary = hand[i]
		if str(card.get("card_id", "")) == card_id:
			return i
	return -1

func _hand_has_suit(hand: Array, suit: String) -> bool:
	for card_raw in hand:
		var card: Dictionary = card_raw
		if str(card.get("suit", "")) == suit:
			return true
	return false

func _is_play_legal(state: Dictionary, seat_id: String, card: Dictionary) -> bool:
	var hand: Array = state.get("hands", {}).get(seat_id, [])

	# The player who revealed the hidden trump must play a trump on that same
	# turn if they hold one. They are void in the lead suit by definition, so
	# this is the only constraint on them; with no trump in hand they are free.
	if str(state.get("must_play_trump_seat_id", "")) == seat_id:
		var forced_suit := str(state.get("trump_suit", ""))
		if forced_suit != "" and _hand_has_suit(hand, forced_suit):
			return str(card.get("suit", "")) == forced_suit

	var lead_suit := str(state.get("lead_suit", ""))
	if lead_suit == "":
		return true
	if _hand_has_suit(hand, lead_suit):
		return str(card.get("suit", "")) == lead_suit
	return true

func _resolve_trick_winner(state: Dictionary) -> String:
	var trick: Array = state.get("trick_cards", [])
	var lead_suit := str(state.get("lead_suit", ""))
	var trump_active := bool(state.get("trump_active", false))
	var trump_suit := str(state.get("trump_suit", ""))
	var winning_entry: Dictionary = trick[0]

	for entry_raw in trick:
		var entry: Dictionary = entry_raw
		var challenger_suit := str(entry.get("suit", ""))
		var winner_suit := str(winning_entry.get("suit", ""))
		var challenger_rank := _rank_value(str(entry.get("rank", "")))
		var winner_rank := _rank_value(str(winning_entry.get("rank", "")))

		if trump_active:
			if challenger_suit == trump_suit and winner_suit != trump_suit:
				winning_entry = entry
				continue
			if challenger_suit == trump_suit and winner_suit == trump_suit and challenger_rank > winner_rank:
				winning_entry = entry
				continue

		if winner_suit != trump_suit and challenger_suit == lead_suit and winner_suit == lead_suit and challenger_rank > winner_rank:
			winning_entry = entry

	return str(winning_entry.get("seat_id", "seat_0"))

func _finish_trick_if_needed(state: Dictionary) -> Dictionary:
	var trick: Array = state.get("trick_cards", [])
	var player_count := int(state.get("player_count", ROOM_SIZE))
	if trick.size() < player_count:
		return state

	var winner_seat := _resolve_trick_winner(state)
	var team := _team_for_seat(winner_seat)
	state["captured_tricks"][team] = int(state["captured_tricks"].get(team, 0)) + 1

	var tens_in_trick: Array = []
	for entry_raw in trick:
		var entry: Dictionary = entry_raw
		if str(entry.get("rank", "")) == "10":
			state["captured_10s"][team] = int(state["captured_10s"].get(team, 0)) + 1
			tens_in_trick.append({"suit": str(entry.get("suit", "")), "rank": "10"})

	var captured_ten_cards: Dictionary = state.get("captured_ten_cards", {"A": [], "B": []})
	var team_tens: Array = captured_ten_cards.get(team, [])
	for ten in tens_in_trick:
		team_tens.append(ten)
	captured_ten_cards[team] = team_tens
	state["captured_ten_cards"] = captured_ten_cards

	# Publish the completed trick so clients can animate it into the winning
	# team's captured pile. The sequence number lets a client tell a new
	# capture apart from a resend of the same snapshot.
	var trick_seq := int(state.get("trick_seq", 0)) + 1
	state["trick_seq"] = trick_seq
	state["last_trick"] = {
		"seq": trick_seq,
		"winner_seat_id": winner_seat,
		"team": team,
		"cards": trick.duplicate(true),
		"tens": tens_in_trick,
		"pile_index": int(state["captured_tricks"].get(team, 1)) - 1,
		"lead_suit": str(state.get("lead_suit", "")),
		"trump_suit": str(state.get("trump_suit", "")),
		"trump_active": bool(state.get("trump_active", false))
	}

	state["trick_cards"] = []
	state["lead_suit"] = ""
	state["current_leader_seat_id"] = winner_seat
	state["current_turn_seat_id"] = winner_seat

	var any_cards_left := false
	for hand in state.get("hands", {}).values():
		if (hand as Array).size() > 0:
			any_cards_left = true
			break

	# A team that has taken all four 10s has already won the court, so the rest
	# of the hand cannot change anything: end the game here instead of making
	# everyone play out dead tricks. Hands are left untouched so clients can
	# clear the table with the usual next-game animation.
	var court_secured := int(state["captured_10s"].get(team, 0)) >= TENS_IN_DECK

	if not any_cards_left or court_secured:
		state = _finish_game(state, court_secured and any_cards_left)

	return state

func _finish_game(state: Dictionary, ended_early: bool = false) -> Dictionary:
	var tens_a := int(state["captured_10s"].get("A", 0))
	var tens_b := int(state["captured_10s"].get("B", 0))
	var tricks_a := int(state["captured_tricks"].get("A", 0))
	var tricks_b := int(state["captured_tricks"].get("B", 0))
	var winner := "A"
	var court := false
	var is_draw := false

	if tens_a == 4 or tens_b == 4:
		court = true
		winner = "A" if tens_a == 4 else "B"
	elif tens_a != tens_b:
		winner = "A" if tens_a > tens_b else "B"
	elif tricks_a != tricks_b:
		winner = "A" if tricks_a > tricks_b else "B"
	else:
		# Equal 10s and equal tricks (possible in 6/8 player games):
		# no points, same dealer deals the next game.
		is_draw = true

	if is_draw:
		state["last_game_result"] = {
			"winner": "",
			"court": false,
			"points": 0,
			"draw": true,
			"ended_early": false,
			"captured_10s": state["captured_10s"].duplicate(true),
			"captured_tricks": state["captured_tricks"].duplicate(true)
		}
		state["phase"] = "game_result"
		return state

	var points := 5 if court else 2
	state["scores"][winner] = int(state["scores"].get(winner, 0)) + points
	state["last_game_result"] = {
		"winner": winner,
		"court": court,
		"points": points,
		"draw": false,
		"ended_early": ended_early,
		"captured_10s": state["captured_10s"].duplicate(true),
		"captured_tricks": state["captured_tricks"].duplicate(true)
	}
	var target_score := int(state.get("target_score", TARGET_SCORE))
	state["phase"] = "match_result" if int(state["scores"].get(winner, 0)) >= target_score else "game_result"
	return state

func _choose_bot_card(state: Dictionary, seat_id: String) -> String:
	var hand: Array = state.get("hands", {}).get(seat_id, [])
	if hand.is_empty():
		return ""

	# A bot that opened the trump owes a trump card, same as a human.
	if str(state.get("must_play_trump_seat_id", "")) == seat_id:
		var forced_suit := str(state.get("trump_suit", ""))
		for card_raw in hand:
			var forced: Dictionary = card_raw
			if str(forced.get("suit", "")) == forced_suit:
				return str(forced.get("card_id", ""))

	var lead_suit := str(state.get("lead_suit", ""))
	if lead_suit != "":
		for card_raw in hand:
			var card: Dictionary = card_raw
			if str(card.get("suit", "")) == lead_suit:
				return str(card.get("card_id", ""))
	return str((hand[0] as Dictionary).get("card_id", ""))

func _seat_is_bot(room: Dictionary, seat_id: String) -> bool:
	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		if str(p.get("seat_id", "")) == seat_id:
			return bool(p.get("is_bot", false))
	return false

func _maybe_run_bot_turn(code: String) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return
	if bool(state.get("resolving", false)) or bool(state.get("revealing_trump", false)):
		return
	var current_seat := str(state.get("current_turn_seat_id", ""))
	if not _seat_is_bot(room, current_seat):
		return
	if bool(room.get("bot_turn_scheduled", false)):
		return
	room["bot_turn_scheduled"] = true
	rooms[code] = room
	_run_bot_turn_after_delay(code)

func _run_bot_turn_after_delay(code: String) -> void:
	await get_tree().create_timer(BOT_PLAY_DELAY_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	room["bot_turn_scheduled"] = false
	rooms[code] = room
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return
	if bool(state.get("resolving", false)) or bool(state.get("revealing_trump", false)):
		return
	var current_seat := str(state.get("current_turn_seat_id", ""))
	if not _seat_is_bot(room, current_seat):
		return
	var card_id := _choose_bot_card(state, current_seat)
	if card_id != "":
		_apply_play_card_action(code, current_seat, card_id)

func _maybe_schedule_next_game(code: String) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if str(state.get("phase", "")) != "game_result":
		return
	if bool(room.get("next_game_scheduled", false)):
		return
	room["next_game_scheduled"] = true
	rooms[code] = room
	var court := bool((state.get("last_game_result", {}) as Dictionary).get("court", false))
	_start_next_game_after_delay(code, COURT_RESULT_DELAY_S if court else NEXT_GAME_DELAY_S)

func _start_next_game_after_delay(code: String, delay: float = NEXT_GAME_DELAY_S) -> void:
	await get_tree().create_timer(delay).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	room["next_game_scheduled"] = false
	rooms[code] = room
	var state: Dictionary = room.get("match_state", {})
	if str(state.get("phase", "")) != "game_result":
		return
	_start_next_game(code)

func _start_next_game(code: String) -> void:
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	var player_count := int(settings.get("player_count", 4))
	var direction := str(settings.get("play_direction", "counter_clockwise"))
	var result: Dictionary = state.get("last_game_result", {})
	var dealer := str(state.get("dealer_seat_id", "seat_0"))
	var winner := str(result.get("winner", ""))

	# Dealer rotation rules:
	# dealer team wins (normal or court) -> dealer passes to next player
	# dealer team loses normal          -> same dealer deals again
	# dealer team loses court           -> skip one, player after next deals
	# draw                              -> same dealer deals again
	var new_dealer := dealer
	if winner != "":
		if winner == _team_for_seat(dealer):
			new_dealer = _next_seat(dealer, player_count, direction)
		elif bool(result.get("court", false)):
			new_dealer = _next_seat(_next_seat(dealer, player_count, direction), player_count, direction)

	room["dealer_seat_id"] = new_dealer
	room["trump_holder_seat_id"] = _next_seat(new_dealer, player_count, direction)
	var carried_scores: Dictionary = state.get("scores", {"A": 0, "B": 0}).duplicate(true)
	var new_state := _create_match_state(room)
	new_state["scores"] = carried_scores
	room["match_state"] = new_state
	rooms[code] = room
	_broadcast_match_state(code)
	_maybe_auto_choose_trump_for_bot(code)

func _arm_action_deadline(code: String) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]

	# Every broadcast invalidates any previously armed deadline, then arms a
	# fresh one if the current phase is waiting on a human.
	var token := int(room.get("deadline_token", 0)) + 1
	room["deadline_token"] = token
	rooms[code] = room

	var state: Dictionary = room.get("match_state", {})
	var phase := str(state.get("phase", ""))
	var seat := ""
	var wait_time := TURN_DEADLINE_S
	if phase == "playing":
		if bool(state.get("resolving", false)) or bool(state.get("revealing_trump", false)):
			return
		seat = str(state.get("current_turn_seat_id", ""))
	elif phase == "trump_mode_choice" or phase == "closed_trump_card_choice":
		seat = str(state.get("trump_holder_seat_id", ""))
		wait_time = CHOICE_DEADLINE_S
	else:
		return
	if seat == "" or _seat_is_bot(room, seat):
		return
	_run_action_deadline(code, token, phase, seat, wait_time)

func _run_action_deadline(code: String, token: int, phase: String, seat: String, wait_time: float) -> void:
	await get_tree().create_timer(wait_time).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	if int(room.get("deadline_token", -1)) != token:
		return
	var state: Dictionary = room.get("match_state", {})
	if str(state.get("phase", "")) != phase:
		return
	if phase == "playing":
		if bool(state.get("resolving", false)):
			return
		if str(state.get("current_turn_seat_id", "")) != seat:
			return
		var card_id := _choose_bot_card(state, seat)
		if card_id != "":
			_apply_play_card_action(code, seat, card_id)
	elif phase == "trump_mode_choice":
		_apply_trump_mode_choice(code, seat, "open")
	elif phase == "closed_trump_card_choice":
		var hand: Array = state.get("hands", {}).get(seat, [])
		if not hand.is_empty():
			_apply_hidden_trump_choice(code, seat, str((hand[0] as Dictionary).get("card_id", "")))

func _apply_play_card_action(code: String, seat_id: String, card_id: String) -> void:
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return
	if bool(state.get("resolving", false)) or bool(state.get("revealing_trump", false)):
		return
	if str(state.get("current_turn_seat_id", "")) != seat_id:
		return
	if (state.get("trick_cards", []) as Array).size() >= int(state.get("player_count", ROOM_SIZE)):
		return

	var hand: Array = state.get("hands", {}).get(seat_id, [])
	var card_index := _find_card_index(hand, card_id)
	if card_index == -1:
		return
	var card: Dictionary = hand[card_index]
	if not _is_play_legal(state, seat_id, card):
		return

	var lead_suit := str(state.get("lead_suit", ""))
	var was_void := lead_suit != "" and not _hand_has_suit(hand, lead_suit)
	hand.remove_at(card_index)
	state["hands"][seat_id] = hand
	if str(state.get("must_play_trump_seat_id", "")) == seat_id:
		state["must_play_trump_seat_id"] = ""

	if lead_suit == "":
		state["lead_suit"] = str(card.get("suit", ""))
	elif state.get("trump_mode", "") == "open" and not bool(state.get("trump_active", false)) and was_void:
		state["trump_active"] = true
		state["trump_suit"] = str(card.get("suit", ""))

	state["trick_cards"].append({
		"seat_id": seat_id,
		"card_id": card.get("card_id", ""),
		"id": card.get("id", 0),
		"suit": card.get("suit", ""),
		"rank": card.get("rank", ""),
		"was_trump_at_play_time": bool(state.get("trump_active", false)) and str(card.get("suit", "")) == str(state.get("trump_suit", ""))
	})

	var player_count := int(state.get("player_count", ROOM_SIZE))
	var play_direction := str(state.get("play_direction", "counter_clockwise"))
	if state["trick_cards"].size() < player_count:
		state["current_turn_seat_id"] = _next_seat(seat_id, player_count, play_direction)
		room["match_state"] = state
		rooms[code] = room
		_broadcast_match_state(code)
		return

	# Trick is complete: pause with all cards visible before resolving,
	# so every client can see the final card land.
	state["resolving"] = true
	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)
	_finish_trick_after_pause(code)

func _finish_trick_after_pause(code: String) -> void:
	await get_tree().create_timer(TRICK_RESOLVE_PAUSE_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return
	if not bool(state.get("resolving", false)):
		return
	state = _finish_trick_if_needed(state)
	state["resolving"] = false
	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)

func _broadcast_dealer_draw(code: String) -> void:
	var room: Dictionary = rooms.get(code, {})
	var data := {
		"players": room.get("players", []),
		"phase": room.get("phase", "dealer_draw"),
		"dealer_draw_cards": room.get("dealer_draw_cards", []),
		"dealer_seat_id": room.get("dealer_seat_id", ""),
		"trump_holder_seat_id": room.get("trump_holder_seat_id", ""),
		"trump_mode": room.get("trump_mode", "")
	}

	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		if bool(p.get("is_bot", false)):
			continue
		if room.get("phase", "") == "trump_mode_choice":
			_network_manager().rpc_id(int(p.get("peer_id", -1)), "_client_trump_mode_choice_requested", data)
		else:
			_network_manager().rpc_id(int(p.get("peer_id", -1)), "_client_dealer_draw_updated", data)

func _decide_dealer_from_draw(code: String) -> void:
	var room: Dictionary = rooms[code]
	var best_card: Dictionary = {}
	for card_raw in room.get("dealer_draw_cards", []):
		var card: Dictionary = card_raw
		if best_card.is_empty() or _rank_value(str(card.get("rank", ""))) > _rank_value(str(best_card.get("rank", ""))):
			best_card = card

	var dealer_seat := str(best_card.get("claimed_by_seat_id", "seat_0"))
	var dealer_index := int(dealer_seat.trim_prefix("seat_"))
	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	var player_count := int(settings.get("player_count", 4))
	var step := 1 if str(settings.get("play_direction", "counter_clockwise")) == "counter_clockwise" else -1
	var trump_holder_index := (dealer_index + step + player_count) % player_count
	room["dealer_seat_id"] = dealer_seat
	room["trump_holder_seat_id"] = "seat_%d" % trump_holder_index
	# Hold on the finished draw so everyone can see the revealed cards and
	# who won the deal before the table is cleared for dealing.
	room["phase"] = "dealer_decided"
	rooms[code] = room
	_broadcast_dealer_draw(code)
	_begin_match_after_dealer_reveal(code)

func _begin_match_after_dealer_reveal(code: String) -> void:
	await get_tree().create_timer(DEALER_REVEAL_HOLD_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	if str(room.get("phase", "")) != "dealer_decided":
		return
	room["phase"] = "match"
	room["match_state"] = _create_match_state(room)
	rooms[code] = room
	_start_server_match_scene(code)
	_broadcast_match_state(code)
	_maybe_auto_choose_trump_for_bot(code)

func _maybe_auto_choose_trump_for_bot(code: String) -> void:
	var room: Dictionary = rooms.get(code, {})
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "trump_mode_choice":
		return

	var trump_holder := str(state.get("trump_holder_seat_id", ""))
	if not _seat_is_bot(room, trump_holder):
		return

	# Let clients finish animating the first batch before the bot decides.
	await get_tree().create_timer(BOT_CHOICE_DELAY_S).timeout
	if not rooms.has(code):
		return
	if str(rooms[code].get("match_state", {}).get("phase", "")) != "trump_mode_choice":
		return
	_apply_trump_mode_choice(code, trump_holder, "hidden")

func _start_server_match_scene(code: String) -> void:
	var room: Dictionary = rooms[code]
	var setup := {
		"players": room.get("players", []),
		"host_peer_id": _get_room_host_peer(room),
		"phase": "server_match",
		"dealer_seat_id": room.get("dealer_seat_id", "seat_0"),
		"trump_holder_seat_id": room.get("trump_holder_seat_id", "seat_1"),
		"trump_mode": "",
		"server_authoritative": true
	}

	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		if bool(p.get("is_bot", false)):
			continue
		_network_manager().rpc_id(int(p.get("peer_id", -1)), "_client_start_match", setup)

func _apply_trump_mode_choice(code: String, seat_id: String, mode: String) -> void:
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "trump_mode_choice":
		return
	if str(state.get("trump_holder_seat_id", "")) != seat_id:
		return

	state["trump_mode"] = "open" if mode == "open" else "hidden"
	var dealt_remaining := false
	if state["trump_mode"] == "open":
		state = _deal_remaining_cards(state)
		dealt_remaining = true
	else:
		state["phase"] = "closed_trump_card_choice"

	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)
	if dealt_remaining:
		_start_play_after_deal(code)
	else:
		_maybe_auto_choose_hidden_trump_for_bot(code)

func _maybe_auto_choose_hidden_trump_for_bot(code: String) -> void:
	var room: Dictionary = rooms.get(code, {})
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "closed_trump_card_choice":
		return

	var holder := str(state.get("trump_holder_seat_id", ""))
	if not _seat_is_bot(room, holder):
		return

	await get_tree().create_timer(BOT_CHOICE_DELAY_S).timeout
	if not rooms.has(code):
		return
	var current: Dictionary = rooms[code].get("match_state", {})
	if str(current.get("phase", "")) != "closed_trump_card_choice":
		return
	var hand: Array = current.get("hands", {}).get(holder, [])
	if not hand.is_empty():
		_apply_hidden_trump_choice(code, holder, str((hand[0] as Dictionary).get("card_id", "")))

func _apply_hidden_trump_choice(code: String, seat_id: String, card_id: String) -> void:
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "closed_trump_card_choice":
		return
	if str(state.get("trump_holder_seat_id", "")) != seat_id:
		return

	var hand: Array = state.get("hands", {}).get(seat_id, [])
	var card_index := _find_card_index(hand, card_id)
	if card_index == -1:
		return

	var card: Dictionary = hand[card_index]
	hand.remove_at(card_index)
	state["hands"][seat_id] = hand
	state["hidden_trump"] = {
		"card_id": card.get("card_id", ""),
		"id": card.get("id", 0),
		"suit": card.get("suit", ""),
		"rank": card.get("rank", ""),
		"holder_seat_id": seat_id,
		"is_set_aside": true,
		"is_revealed": false,
		"has_returned_to_hand": false
	}
	state = _deal_remaining_cards(state)
	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)
	_start_play_after_deal(code)

func _apply_hidden_trump_reveal(code: String, seat_id: String) -> void:
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if state.get("phase", "") != "playing":
		return
	if str(state.get("current_turn_seat_id", "")) != seat_id:
		return
	if state.get("trump_mode", "") != "hidden" or bool(state.get("trump_active", false)):
		return
	var lead_suit := str(state.get("lead_suit", ""))
	if lead_suit == "":
		return
	var hand: Array = state.get("hands", {}).get(seat_id, [])
	if _hand_has_suit(hand, lead_suit):
		return

	var hidden_trump: Dictionary = state.get("hidden_trump", {})
	var holder := str(hidden_trump.get("holder_seat_id", ""))
	if holder == "":
		return

	# Phase 1: flip the hidden trump face up in its slot for everyone.
	# Play stays blocked while revealing_trump is true.
	state["trump_active"] = true
	state["trump_suit"] = str(hidden_trump.get("suit", ""))
	hidden_trump["is_revealed"] = true
	hidden_trump["is_set_aside"] = true
	hidden_trump["has_returned_to_hand"] = false
	state["hidden_trump"] = hidden_trump
	state["revealing_trump"] = true
	# Whoever opened the trump owes a trump card this turn if they hold one.
	# Cleared as soon as they play; see _is_play_legal.
	state["must_play_trump_seat_id"] = seat_id

	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)
	_return_hidden_trump_after_reveal(code, holder)

func _return_hidden_trump_after_reveal(code: String, holder: String) -> void:
	await get_tree().create_timer(TRUMP_REVEAL_HOLD_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var state: Dictionary = room.get("match_state", {})
	if not bool(state.get("revealing_trump", false)):
		return

	# Phase 2: the revealed card goes back to the trump holder's hand.
	var hidden_trump: Dictionary = state.get("hidden_trump", {})
	hidden_trump["is_set_aside"] = false
	hidden_trump["has_returned_to_hand"] = true
	state["hidden_trump"] = hidden_trump
	state["revealing_trump"] = false

	var hands: Dictionary = state.get("hands", {})
	if hands.has(holder):
		var holder_hand: Array = hands[holder]
		if _find_card_index(holder_hand, str(hidden_trump.get("card_id", ""))) == -1:
			holder_hand.append({
				"card_id": hidden_trump.get("card_id", ""),
				"id": hidden_trump.get("id", 0),
				"suit": hidden_trump.get("suit", ""),
				"rank": hidden_trump.get("rank", "")
			})
			hands[holder] = holder_hand
			state["hands"] = hands

	room["match_state"] = state
	rooms[code] = room
	_broadcast_match_state(code)

func _claim_bot_dealer_draw_cards(room: Dictionary) -> Dictionary:
	var cards: Array = room.get("dealer_draw_cards", [])
	var players: Array = room.get("players", [])

	for player_raw in players:
		var player: Dictionary = player_raw
		if not bool(player.get("is_bot", false)):
			continue

		var already_claimed := false
		for claimed_raw in cards:
			var claimed: Dictionary = claimed_raw
			if str(claimed.get("claimed_by_player_id", "")) == str(player.get("id", "")):
				already_claimed = true
				break
		if already_claimed:
			continue

		for i in range(cards.size()):
			var card: Dictionary = cards[i]
			if not bool(card.get("is_claimed", false)):
				card["is_claimed"] = true
				card["claimed_by_player_id"] = str(player.get("id", ""))
				card["claimed_by_seat_id"] = str(player.get("seat_id", ""))
				cards[i] = card
				break

	room["dealer_draw_cards"] = cards
	return room

@rpc("any_peer")
func _server_create_room(player: Dictionary, room_settings: Dictionary = {}, sender_peer_id: int = 0) -> void:
	var peer_id := sender_peer_id
	if peer_id == 0:
		peer_id = multiplayer.get_remote_sender_id()
	var code := _generate_room_code()
	var settings := _normalize_room_settings(room_settings)
	var players := [_normalize_player(player, peer_id)]
	rooms[code] = {
		"code": code,
		"settings": settings,
		"players": _lock_team_choices(_assign_seats(players, int(settings.get("player_count", 4)))),
		"spectators": [],
		"phase": "lobby",
		"dealer_draw_cards": [],
		"dealer_seat_id": "seat_0",
		"trump_holder_seat_id": "seat_1",
		"trump_mode": ""
	}
	peer_to_room[peer_id] = code
	_network_manager().rpc_id(peer_id, "_client_room_created", code)
	_broadcast_lobby(code)

@rpc("any_peer")
func _server_join_room(code: String, player: Dictionary, as_spectator: bool = false, sender_peer_id: int = 0) -> void:
	var peer_id := sender_peer_id
	if peer_id == 0:
		peer_id = multiplayer.get_remote_sender_id()
	code = code.to_upper()
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	var players: Array = room.get("players", [])
	var player_id := str(player.get("id", ""))

	var existing_index := _find_player_index(players, player_id)
	if existing_index != -1:
		var existing: Dictionary = players[existing_index]
		existing["peer_id"] = peer_id
		existing["is_connected"] = true
		players[existing_index] = existing
		room["players"] = players
		rooms[code] = room
		peer_to_room[peer_id] = code
		_network_manager().rpc_id(peer_id, "_client_room_joined", code)
		_broadcast_lobby(code)
		if room.has("match_state"):
			_broadcast_match_state(code)
		return

	if as_spectator or players.size() >= int(settings.get("player_count", 4)):
		if not bool(settings.get("spectators_enabled", true)):
			return
		var spectators: Array = room.get("spectators", [])
		var spectator := _normalize_player(player, peer_id)
		spectator["seat_id"] = "spectator"
		spectator["is_spectator"] = true
		spectators.append(spectator)
		room["spectators"] = spectators
	else:
		players.append(_normalize_player(player, peer_id))
		room["players"] = _lock_team_choices(_assign_seats(players, int(settings.get("player_count", 4))))

	rooms[code] = room
	peer_to_room[peer_id] = code
	_network_manager().rpc_id(peer_id, "_client_room_joined", code)
	_broadcast_lobby(code)

@rpc("any_peer")
func _server_set_ready(code: String, player_id: String, is_ready: bool, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var players: Array = room.get("players", [])
	var index := _find_player_index(players, player_id)
	if index == -1:
		return

	var p: Dictionary = players[index]
	if not _is_sender_for_player(p, sender_peer_id):
		return
	p["ready"] = is_ready
	players[index] = p
	room["players"] = players
	rooms[code] = room
	_broadcast_lobby(code)

@rpc("any_peer")
func _server_set_team(code: String, player_id: String, team: String, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	# Seats are locked once the match has started.
	if str(room.get("phase", "lobby")) != "lobby":
		return

	var players: Array = room.get("players", [])
	var index := _find_player_index(players, player_id)
	if index == -1:
		return

	var p: Dictionary = players[index]
	if not _is_sender_for_player(p, sender_peer_id):
		return

	if team != "A" and team != "B":
		return

	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	var player_count := int(settings.get("player_count", 4))
	# A full side cannot take another player; the request is simply ignored so
	# the client keeps the seat it already had.
	if _team_choice_count(players, team, player_id) >= _team_capacity(player_count):
		return

	p["team_choice"] = team
	players[index] = p
	room["players"] = _assign_seats(players, player_count)
	rooms[code] = room
	_broadcast_lobby(code)

@rpc("any_peer")
func _server_start_match(code: String, player_id: String, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var sender := sender_peer_id
	if sender == 0:
		sender = multiplayer.get_remote_sender_id()
	var room: Dictionary = rooms[code]
	if sender != _get_room_host_peer(room):
		return

	var settings: Dictionary = room.get("settings", _normalize_room_settings({}))
	if bool(settings.get("bots_enabled", true)):
		room["players"] = _fill_bots(room.get("players", []), int(settings.get("player_count", 4)))
	elif room.get("players", []).size() < int(settings.get("player_count", 4)):
		return
	room["phase"] = "dealer_draw"
	room["dealer_draw_cards"] = _create_dealer_draw_cards(int(settings.get("player_count", 4)))
	rooms[code] = room
	_broadcast_dealer_draw(code)
	_arm_dealer_draw_deadline(code)

func _arm_dealer_draw_deadline(code: String) -> void:
	await get_tree().create_timer(CHOICE_DEADLINE_S).timeout
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	if str(room.get("phase", "")) != "dealer_draw":
		return

	# Auto-claim remaining cards for players who never picked one.
	var cards: Array = room.get("dealer_draw_cards", [])
	for p_raw in room.get("players", []):
		var p: Dictionary = p_raw
		var pid := str(p.get("id", ""))
		var has_claim := false
		for c_raw in cards:
			var c: Dictionary = c_raw
			if str(c.get("claimed_by_player_id", "")) == pid:
				has_claim = true
				break
		if has_claim:
			continue
		for i in range(cards.size()):
			var c: Dictionary = cards[i]
			if not bool(c.get("is_claimed", false)):
				c["is_claimed"] = true
				c["claimed_by_player_id"] = pid
				c["claimed_by_seat_id"] = str(p.get("seat_id", ""))
				cards[i] = c
				break

	room["dealer_draw_cards"] = cards
	rooms[code] = room
	_broadcast_dealer_draw(code)
	_decide_dealer_from_draw(code)

@rpc("any_peer")
func _server_claim_dealer_draw_card(code: String, player_id: String, draw_index: int, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	if room.get("phase", "") != "dealer_draw":
		return

	var players: Array = room.get("players", [])
	var player := _find_player_by_id(players, player_id)
	if player.is_empty():
		return
	if not _is_sender_for_player(player, sender_peer_id):
		return

	var cards: Array = room.get("dealer_draw_cards", [])
	for card_raw in cards:
		var claimed_card: Dictionary = card_raw
		if str(claimed_card.get("claimed_by_player_id", "")) == player_id:
			return

	for i in range(cards.size()):
		var card: Dictionary = cards[i]
		if int(card.get("draw_index", -1)) == draw_index and not bool(card.get("is_claimed", false)):
			card["is_claimed"] = true
			card["claimed_by_player_id"] = player_id
			card["claimed_by_seat_id"] = str(player.get("seat_id", ""))
			cards[i] = card
			break

	room["dealer_draw_cards"] = cards
	room = _claim_bot_dealer_draw_cards(room)
	rooms[code] = room
	_broadcast_dealer_draw(code)

	var all_claimed := true
	for card_raw in room.get("dealer_draw_cards", []):
		var card: Dictionary = card_raw
		if not bool(card.get("is_claimed", false)):
			all_claimed = false
			break

	if all_claimed:
		_decide_dealer_from_draw(code)

@rpc("any_peer")
func _server_choose_trump_mode(code: String, player_id: String, mode: String, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var player := _find_player_by_id(room.get("players", []), player_id)
	if player.is_empty():
		return
	if not _is_sender_for_player(player, sender_peer_id):
		return

	_apply_trump_mode_choice(code, str(player.get("seat_id", "")), mode)

@rpc("any_peer")
func _server_receive_game_action(code: String, player_id: String, action: Dictionary, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var player := _find_player_by_id(room.get("players", []), player_id)
	if player.is_empty() or bool(player.get("is_bot", false)):
		return
	if not _is_sender_for_player(player, sender_peer_id):
		return

	var seat_id := str(player.get("seat_id", ""))
	match str(action.get("type", "")):
		"play_card":
			_apply_play_card_action(code, seat_id, str(action.get("card_id", "")))
		"confirm_hidden_trump":
			_apply_hidden_trump_choice(code, seat_id, str(action.get("card_id", "")))
		"open_trump":
			_apply_hidden_trump_reveal(code, seat_id)

@rpc("any_peer")
func _server_request_rematch(code: String, player_id: String, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var sender := sender_peer_id
	if sender == 0:
		sender = multiplayer.get_remote_sender_id()
	var room: Dictionary = rooms[code]
	if sender != _get_room_host_peer(room):
		return

	var state: Dictionary = room.get("match_state", {})
	if str(state.get("phase", "")) != "match_result":
		return
	var player := _find_player_by_id(room.get("players", []), player_id)
	if player.is_empty():
		return

	# Same table, same seats, scores back to zero. The deal passes on exactly
	# as it would have between games.
	state["scores"] = {"A": 0, "B": 0}
	room["match_state"] = state
	rooms[code] = room
	_start_next_game(code)

@rpc("any_peer")
func _server_request_game_state(code: String, player_id: String, sender_peer_id: int = 0) -> void:
	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var player := _find_player_by_id(room.get("players", []), player_id)
	if player.is_empty():
		return
	if not _is_sender_for_player(player, sender_peer_id):
		return
	if not room.has("match_state"):
		return

	_network_manager().rpc_id(int(player.get("peer_id", -1)), "_client_receive_game_state", _build_client_snapshot(room, str(player.get("seat_id", ""))))

@rpc("any_peer")
@warning_ignore("unused_parameter")
func _server_broadcast_game_state(code: String, player_id: String, snapshots_by_peer: Dictionary, sender_peer_id: int = 0) -> void:
	# Disabled: the server is authoritative. Clients (including the room host)
	# must never be able to push game state to other clients.
	return
