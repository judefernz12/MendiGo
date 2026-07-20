extends Node

func _ready() -> void:
	# Dedicated server exports (Render/Docker) must boot straight into the
	# server scene: exported binaries cannot take a scene path on the
	# command line. The "dedicated_server" feature tag is set automatically
	# by the Linux dedicated-server export preset. "--server" (after "--")
	# allows forcing server mode on any build for local testing.
	if OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server"):
		call_deferred("goto_scene", "res://scenes/game/Server.tscn")
		return

	call_deferred("goto_scene", "res://scenes/ui/Home.tscn")

func goto_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)
