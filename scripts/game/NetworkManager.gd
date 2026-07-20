extends Node

# Compatibility wrapper for older scene references.
# The active multiplayer singleton is res://scripts/network/NetworkManager.gd.

func host_game() -> void:
	push_warning("Local ENet hosting is disabled. Use the dedicated WebSocket server.")

func join_game(_ip: String = "") -> void:
	var autoload := get_node_or_null("/root/NetworkManager")
	if autoload != null and autoload.has_method("connect_to_server"):
		autoload.connect_to_server("Player")
