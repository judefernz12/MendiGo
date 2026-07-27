extends Node

signal connected_to_server
signal connection_failed
signal disconnected_from_server
signal lobby_updated(players, settings)
signal room_created(room_code)
signal room_joined(room_code)
signal start_match(match_setup)
signal game_state_snapshot_received(snapshot)
signal game_action_received(action)
signal dealer_draw_updated(match_data)
signal trump_mode_choice_requested(match_data)
signal room_error(message)

var peer: MultiplayerPeer = null

# Trusted root certificates shipped with the game. Passing these explicitly
# makes wss:// work reliably on every platform instead of depending on the
# OS certificate store (which Godot fails to read on some setups).
const CA_BUNDLE_PATH := "res://assets/certs/ca-certificates.crt"

# Set this to your real server URL before exporting clients.
# Example (Render): "wss://your-app-name.onrender.com"
var production_websocket_url: String = "wss://mendigo.onrender.com"
var local_websocket_url: String = "ws://127.0.0.1:12345"
var use_local_server: bool = false
var server_host: String = "play.your-domain.com"
var server_port: int = 12345

var current_room_code: String = ""
var local_player_name: String = ""
var local_player_id: String = ""
var current_lobby_players: Array = []
var current_room_settings: Dictionary = {}
var latest_game_state_snapshot: Dictionary = {}

# True when this client is in the room without a seat: it joined a game that
# had already started, the table was full, or it asked to watch.
var is_spectator: bool = false

# Handed from the lobby to the game scene. Kept in memory on purpose: two
# clients running on one machine share user://, so writing this to a file
# made the second client load the first client's seat.
var pending_match_setup: Dictionary = {}

# The last "go to the table" payload the server sent, kept until a scene acts
# on it. Joining a running room answers immediately, which can beat the lobby
# scene into existence - the signal would then fire into nothing and the
# client would sit on the team picker while the game ran without it.
var pending_game_entry: Dictionary = {}

func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# Opt into the local test server without editing code:
	# desktop: run with --local-server, web: append ?local=1 to the page URL.
	if OS.get_cmdline_args().has("--local-server") or OS.get_cmdline_user_args().has("--local-server"):
		use_local_server = true
	if OS.has_feature("web"):
		var search := str(JavaScriptBridge.eval("window.location.search", true))
		if search.contains("local=1"):
			use_local_server = true

const IDENTITY_PATH := "user://identity.cfg"

func _new_player_id() -> String:
	return str(Time.get_unix_time_from_system()) + "_" + str(randi())

func _load_identity() -> void:
	# Kept on disk so a dropped connection can reclaim its seat instead of
	# coming back as a stranger. Two clients on one machine share user://, so
	# the server rejects a second use of a live id and _on_identity_conflict
	# mints a fresh one - see _client_identity_conflict.
	var config := ConfigFile.new()
	if config.load(IDENTITY_PATH) == OK:
		local_player_id = str(config.get_value("identity", "player_id", ""))
	if local_player_id == "":
		local_player_id = _new_player_id()
		_save_identity()

func _save_identity() -> void:
	var config := ConfigFile.new()
	config.set_value("identity", "player_id", local_player_id)
	config.save(IDENTITY_PATH)

func connect_to_server(player_name: String) -> void:
	local_player_name = player_name
	if local_player_id == "":
		_load_identity()

	var ws_peer := WebSocketMultiplayerPeer.new()
	# Free-tier hosting (Render) sleeps when idle and takes 30-60 s to wake.
	# Godot's default handshake timeout is 3 s, which would abort long
	# before the server is up.
	ws_peer.handshake_timeout = 90.0
	var url := local_websocket_url if use_local_server else production_websocket_url
	var err := ws_peer.create_client(url, _make_tls_options(url))
	if err != OK:
		emit_signal("connection_failed")
		return

	peer = ws_peer
	multiplayer.multiplayer_peer = peer

func _make_tls_options(url: String) -> TLSOptions:
	if not url.begins_with("wss://"):
		return null
	if OS.has_feature("web"):
		# Browsers do their own TLS; Godot's options are ignored there.
		return null
	var cert := X509Certificate.new()
	if cert.load(CA_BUNDLE_PATH) != OK:
		push_warning("CA bundle not found at %s; relying on system certificates." % CA_BUNDLE_PATH)
		return null
	return TLSOptions.client(cert)

func disconnect_from_server() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	current_room_code = ""
	current_lobby_players.clear()
	latest_game_state_snapshot.clear()
	pending_game_entry.clear()
	pending_match_setup.clear()
	is_spectator = false

func create_room(room_settings: Dictionary = {}) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_create_room", {
		"id": local_player_id,
		"name": local_player_name
	}, room_settings)

func join_room(room_code: String, as_spectator: bool = false) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_join_room", room_code.to_upper(), {
		"id": local_player_id,
		"name": local_player_name
	}, as_spectator)

func leave_room() -> void:
	# Say so before dropping the socket. Closing alone meant the server did not
	# find out until the WebSocket teardown reached it, and a client that
	# re-dialled and rejoined in the meantime raced its own departure.
	if multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
			and current_room_code != "":
		rpc_id(1, "_server_leave_room", current_room_code, local_player_id)
		# Let the packet actually go out before the socket closes under it.
		await get_tree().create_timer(0.15).timeout

	disconnect_from_server()

func send_ready_state(is_ready: bool) -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_set_ready", current_room_code, local_player_id, is_ready)

func send_team_choice(team: String) -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_set_team", current_room_code, local_player_id, team)

func request_start_match() -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_start_match", current_room_code, local_player_id)

func request_rematch() -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_request_rematch", current_room_code, local_player_id)

func send_game_action(action: Dictionary) -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_receive_game_action", current_room_code, local_player_id, action)

func send_game_state_snapshots(snapshots_by_peer: Dictionary) -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_broadcast_game_state", current_room_code, local_player_id, snapshots_by_peer)

func request_game_state() -> void:
	if multiplayer.multiplayer_peer == null or current_room_code == "":
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	rpc_id(1, "_server_request_game_state", current_room_code, local_player_id)

func claim_dealer_draw_card(draw_index: int) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if current_room_code == "":
		return

	rpc_id(1, "_server_claim_dealer_draw_card", current_room_code, local_player_id, draw_index)

func choose_trump_mode(mode: String) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if current_room_code == "":
		return

	rpc_id(1, "_server_choose_trump_mode", current_room_code, local_player_id, mode)

func _on_connected_to_server() -> void:
	emit_signal("connected_to_server")

func _on_connection_failed() -> void:
	emit_signal("connection_failed")

func _on_server_disconnected() -> void:
	current_room_code = ""
	current_lobby_players.clear()
	emit_signal("disconnected_from_server")

@rpc("authority")
func _client_room_created(room_code: String) -> void:
	current_room_code = room_code
	is_spectator = false
	emit_signal("room_created", room_code)

@rpc("authority")
func _client_room_error(message: String) -> void:
	emit_signal("room_error", message)

@rpc("authority")
func _client_identity_conflict() -> void:
	# This machine's saved id is already sitting in the room (a second client
	# on the same PC). Take a fresh one and try again as a new player.
	local_player_id = _new_player_id()
	_save_identity()
	emit_signal("room_error", "That seat is already taken by another window. Rejoining as a new player.")
	if current_room_code != "":
		join_room(current_room_code, is_spectator)

@rpc("authority")
func _client_room_joined(room_code: String, as_spectator: bool = false) -> void:
	current_room_code = room_code
	is_spectator = as_spectator
	emit_signal("room_joined", room_code)

@rpc("authority")
func _client_lobby_updated(players: Array, settings: Dictionary = {}) -> void:
	current_lobby_players = players.duplicate(true)
	current_room_settings = settings.duplicate(true)
	emit_signal("lobby_updated", current_lobby_players, current_room_settings)

@rpc("authority")
func _client_start_match(match_setup: Dictionary) -> void:
	_remember_game_entry("start_match", match_setup)
	emit_signal("start_match", match_setup)

func _remember_game_entry(kind: String, data: Dictionary) -> void:
	if bool(data.get("is_spectator", false)):
		is_spectator = true
	pending_game_entry = {"kind": kind, "data": data.duplicate(true)}

@rpc("authority")
func _client_receive_game_state(snapshot: Dictionary) -> void:
	latest_game_state_snapshot = snapshot.duplicate(true)
	emit_signal("game_state_snapshot_received", snapshot)

@rpc("authority")
func _client_receive_game_action(action: Dictionary) -> void:
	emit_signal("game_action_received", action)

@rpc("authority")
func _client_dealer_draw_updated(match_data: Dictionary) -> void:
	_remember_game_entry("dealer_draw", match_data)
	emit_signal("dealer_draw_updated", match_data)

@rpc("authority")
func _client_trump_mode_choice_requested(match_data: Dictionary) -> void:
	_remember_game_entry("trump_mode_choice", match_data)
	emit_signal("trump_mode_choice_requested", match_data)

# -------- server rpc stubs: MUST exactly match server signatures --------

@rpc("any_peer")
func _server_create_room(player: Dictionary, room_settings: Dictionary = {}) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_create_room"):
		server._server_create_room(player, room_settings, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_join_room(code: String, player: Dictionary, as_spectator: bool = false) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_join_room"):
		server._server_join_room(code, player, as_spectator, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_leave_room(code: String, player_id: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_leave_room"):
		server._server_leave_room(code, player_id, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_set_ready(code: String, player_id: String, is_ready: bool) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_set_ready"):
		server._server_set_ready(code, player_id, is_ready, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_set_team(code: String, player_id: String, team: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_set_team"):
		server._server_set_team(code, player_id, team, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_start_match(code: String, player_id: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_start_match"):
		server._server_start_match(code, player_id, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_receive_game_action(code: String, player_id: String, action: Dictionary) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_receive_game_action"):
		server._server_receive_game_action(code, player_id, action, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_request_rematch(code: String, player_id: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_request_rematch"):
		server._server_request_rematch(code, player_id, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_request_game_state(code: String, player_id: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_request_game_state"):
		server._server_request_game_state(code, player_id, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_broadcast_game_state(code: String, player_id: String, snapshots_by_peer: Dictionary) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_broadcast_game_state"):
		server._server_broadcast_game_state(code, player_id, snapshots_by_peer, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_claim_dealer_draw_card(code: String, player_id: String, draw_index: int) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_claim_dealer_draw_card"):
		server._server_claim_dealer_draw_card(code, player_id, draw_index, multiplayer.get_remote_sender_id())

@rpc("any_peer")
func _server_choose_trump_mode(code: String, player_id: String, mode: String) -> void:
	var server := get_node_or_null("/root/root")
	if server != null and server.has_method("_server_choose_trump_mode"):
		server._server_choose_trump_mode(code, player_id, mode, multiplayer.get_remote_sender_id())
