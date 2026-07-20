extends RefCounted

# Active deck settings
const CARD_STACK := "stack2"
const CARD_COLOR := "white"

# Internal game suits/ranks
const SUITS := ["clubs", "diamonds", "hearts", "spades"]
const RANKS := ["2", "3", "4", "5", "6", "7", "8", "9", "10", "jack", "queen", "king", "ace"]


static func create_full_deck() -> Array:
	var deck: Array = []
	var next_id: int = 0

	for suit in SUITS:
		for rank in RANKS:
			deck.append({
				"id": next_id,
				"suit": suit,
				"rank": rank
			})
			next_id += 1

	return deck

static func create_deck_for_player_count(player_count: int) -> Array:
	var deck := create_full_deck()

	if player_count == 6 or player_count == 8:
		var filtered: Array = []
		for card in deck:
			if card["rank"] != "2":
				filtered.append(card)
		return filtered

	return deck


static func shuffle_deck(deck: Array) -> Array:
	var shuffled := deck.duplicate()
	shuffled.shuffle()
	return shuffled


static func get_texture_path(card_data: Dictionary) -> String:
	match CARD_STACK:
		"stack2":
			return _get_stack2_texture_path(card_data)
		"stack1":
			return _get_stack1_texture_path(card_data)
		_:
			return _get_stack2_texture_path(card_data)


static func _get_stack2_texture_path(card_data: Dictionary) -> String:
	var suit: String = card_data["suit"]
	var rank: String = card_data["rank"]

	var suit_name := _map_suit_for_stack2(suit)
	var rank_name := _map_rank_for_stack2(rank)

	return "res://assets/cards/stack2/white/%s_%s.png" % [suit_name, rank_name]


static func _get_stack1_texture_path(card_data: Dictionary) -> String:
	var suit: String = card_data["suit"]
	var rank: String = card_data["rank"]

	var suit_name := _map_suit_for_stack1(suit)
	var rank_name := _map_rank_for_stack1(rank)

	return "res://assets/cards/stack1/%s/%s_%s_%s.png" % [
		CARD_COLOR,
		suit_name,
		rank_name,
		CARD_COLOR
	]


static func _map_suit_for_stack2(suit: String) -> String:
	match suit:
		"clubs":
			return "clubs"
		"diamonds":
			return "diamonds"
		"hearts":
			return "hearts"
		"spades":
			return "spades"
		_:
			return suit


static func _map_rank_for_stack2(rank: String) -> String:
	match rank:
		"2":
			return "02"
		"3":
			return "03"
		"4":
			return "04"
		"5":
			return "05"
		"6":
			return "06"
		"7":
			return "07"
		"8":
			return "08"
		"9":
			return "09"
		"10":
			return "10"
		"jack":
			return "jack"
		"queen":
			return "queen"
		"king":
			return "king"
		"ace":
			return "ace"
		_:
			return rank


static func _map_suit_for_stack1(suit: String) -> String:
	match suit:
		"clubs":
			return "Clovers"
		"diamonds":
			return "Tiles"
		"hearts":
			return "Hearts"
		"spades":
			return "Pikes"
		_:
			return suit


static func _map_rank_for_stack1(rank: String) -> String:
	match rank:
		"2":
			return "2"
		"3":
			return "3"
		"4":
			return "4"
		"5":
			return "5"
		"6":
			return "6"
		"7":
			return "7"
		"8":
			return "8"
		"9":
			return "9"
		"10":
			return "10"
		"jack":
			return "Jack"
		"queen":
			return "Queen"
		"king":
			return "King"
		"ace":
			return "A"
		_:
			return rank
