extends Node

func _ready() -> void:
	call_deferred("goto_scene", "res://scenes/ui/Home.tscn")

func goto_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)
