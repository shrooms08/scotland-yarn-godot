extends Node2D

# Draws a ring for move indicators

var _time: float = 0.0
var _pulse_speed: float = 4.0

func _ready():
	set_process(true)
	queue_redraw()

func _process(delta: float):
	_time += delta
	queue_redraw()

func _draw():
	var radius: float = get_meta("radius") if has_meta("radius") else 12.0
	var color: Color = get_meta("color") if has_meta("color") else Color.CYAN
	var width: float = get_meta("width") if has_meta("width") else 2.0
	
	# Pulse effect (alpha only, no size change)
	var pulse = sin(_time * _pulse_speed) * 0.3 + 0.7
	var current_color = color
	current_color.a = color.a * pulse
	
	# Draw main ring
	draw_arc(Vector2.ZERO, radius, 0, TAU, 32, current_color, width)
