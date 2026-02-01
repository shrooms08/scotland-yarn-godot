extends Node2D

signal node_clicked(node_id)

@export var node_id: int = 0

var is_highlighted := false

@onready var button = $ClickButton

func _ready():
	if not button.pressed.is_connected(_on_button_pressed):
		button.pressed.connect(_on_button_pressed)
	button.flat = true

func _on_button_pressed():
	print("Clicked node: ", node_id)
	node_clicked.emit(node_id)

func set_highlight(enabled: bool, color: Color = Color.YELLOW):
	is_highlighted = enabled
	if enabled:
		button.modulate = color
		button.scale = Vector2(1.4, 1.4)
		z_index = 100
	else:
		button.modulate = Color.WHITE
		button.scale = Vector2(1.0, 1.0)
		z_index = 0

func set_player_color(color: Color):
	button.modulate = color
	button.scale = Vector2(1.0, 1.0)
