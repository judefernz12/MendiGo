extends Node3D

const CardDatabase = preload("res://scripts/game/CardDatabase.gd")

signal card_clicked(card: Node3D)

@onready var front: MeshInstance3D = $Front
@onready var back: MeshInstance3D = $Back
@onready var tap_area: Area3D = $TapArea

var clickable := true
var selected := false
var played := false
var is_face_up := false

var is_dealing := false

var home_position := Vector3.ZERO
var home_rotation := Vector3.ZERO
var play_position := Vector3.ZERO
var play_rotation := Vector3.ZERO

var suit: String = ""
var rank: String = ""

var back_texture_path: String = "res://assets/card_backs/back08.png"

var card_id: String = ""

func _ready() -> void:
	tap_area.input_event.connect(_on_tap_area_input_event)
	_ensure_front_material()
	_ensure_back_material()
	set_back_texture(back_texture_path)
	_update_face_visibility()

	front.visible = true
	back.visible = false
	

func _on_tap_area_input_event(camera, event, event_position, normal, shape_idx) -> void:
	if not clickable:
		return

	# Desktop / Web mouse click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			emit_signal("card_clicked", self)
			get_viewport().set_input_as_handled()
			return

	# Android / mobile touch
	if event is InputEventScreenTouch:
		if event.pressed:
			emit_signal("card_clicked", self)
			get_viewport().set_input_as_handled()
			return



func _ensure_front_material() -> StandardMaterial3D:
	var mat := front.material_override as StandardMaterial3D

	if mat != null:
		mat = mat.duplicate()
	else:
		mat = StandardMaterial3D.new()

	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.albedo_color = Color(1, 1, 1, 1)

	front.material_override = mat
	return mat

func _ensure_back_material() -> StandardMaterial3D:
	var mat := back.material_override as StandardMaterial3D

	if mat != null:
		mat = mat.duplicate()
	else:
		mat = StandardMaterial3D.new()

	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.albedo_color = Color(1, 1, 1, 1)

	back.material_override = mat
	return mat

func set_card_data(card_data: Dictionary) -> void:
	if card_data.has("card_id"):
		card_id = str(card_data["card_id"])
	elif card_data.has("id"):
		card_id = str(card_data["id"])
	suit = card_data["suit"]
	rank = card_data["rank"]

	var path := CardDatabase.get_texture_path(card_data)
	if not ResourceLoader.exists(path):
		print("Front texture not found: ", path)
		return

	var tex: Texture2D = load(path)
	var mat := _ensure_front_material()
	mat.albedo_texture = tex

func set_back_texture(path: String) -> void:
	back_texture_path = path

	if not ResourceLoader.exists(path):
		print("Back texture not found: ", path)
		return

	var tex: Texture2D = load(path)
	var mat := _ensure_back_material()
	mat.albedo_texture = tex

func set_home_transform(new_position: Vector3, new_rotation: Vector3) -> void:
	home_position = new_position
	home_rotation = new_rotation
	position = new_position
	rotation_degrees = new_rotation

func set_selected(value: bool) -> void:
	selected = value

	var target_position := home_position
	var target_rotation := home_rotation

	if selected:
		target_position = home_position + Vector3(0, 0.28, 0.1)

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(self, "position", target_position, 0.25)
	tween.parallel().tween_property(self, "rotation_degrees", target_rotation, 0.25)

func play_card() -> void:
	if played:
		return

	played = true
	selected = false

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(self, "position", play_position, 0.35)
	tween.parallel().tween_property(self, "rotation_degrees", play_rotation, 0.35)

func set_face_up(value: bool) -> void:
	is_face_up = value
	_update_face_visibility()

func flip_card() -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)

	tween.tween_property(self, "scale:x", 0.0, 0.12)
	tween.tween_callback(func():
		is_face_up = !is_face_up
		_update_face_visibility()
	)
	tween.tween_property(self, "scale:x", 1.0, 0.12)

func _update_face_visibility() -> void:
	front.visible = is_face_up
	back.visible = not is_face_up
