extends Control

@onready var result_label: Label = %ResultLabel
@onready var play_again_button: Button = %PlayAgainButton
@onready var home_button: Button = %HomeButton

func _ready() -> void:
	play_again_button.pressed.connect(_on_play_again_pressed)
	home_button.pressed.connect(_on_home_pressed)

	result_label.text = "Match Finished"

func _on_play_again_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Lobby.tscn")

func _on_home_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/Home.tscn")
