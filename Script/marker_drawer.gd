extends Node2D

# Draws a filled circle with a label (for player markers)

func _ready():
	queue_redraw()

func _draw():
	var radius: float = get_meta("radius") if has_meta("radius") else 16.0
	var color: Color = get_meta("color") if has_meta("color") else Color.WHITE
	var label_text: String = get_meta("label") if has_meta("label") else ""
	
	# Draw outer ring (darker border)
	var border_color = color.darkened(0.4)
	draw_circle(Vector2.ZERO, radius + 3, border_color)
	
	# Draw main circle
	draw_circle(Vector2.ZERO, radius, color)
	
	# Draw inner highlight
	var highlight_color = color.lightened(0.3)
	draw_circle(Vector2(-radius * 0.2, -radius * 0.2), radius * 0.3, highlight_color)
	
	# Draw label
	if label_text != "":
		var font = ThemeDB.fallback_font
		var font_size = int(radius * 1.2)
		var text_size = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var text_pos = Vector2(-text_size.x / 2, text_size.y / 4)
		
		# Draw text shadow
		draw_string(font, text_pos + Vector2(1, 1), label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.BLACK)
		# Draw text
		draw_string(font, text_pos, label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)
