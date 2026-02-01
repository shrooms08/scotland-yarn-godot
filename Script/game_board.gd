extends Node2D

@onready var node_container = $NodeContainer
@onready var round_label = $CanvasLayer/UI/TopPanel/TopBar/RoundLabel
@onready var turn_label = $CanvasLayer/UI/TopPanel/TopBar/TurnLabel
@onready var status_label = $CanvasLayer/UI/TopPanel/TopBar/StatusLabel
@onready var mr_x_transport_label = $CanvasLayer/UI/BottomPanel/PlayerInfo/MrXTransport
@onready var ticket_buttons = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons
@onready var taxi_button = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons/TaxiButton
@onready var bus_button = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons/BusButton
@onready var underground_button = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons/UndergroundButton
@onready var black_button = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons/BlackButton
@onready var double_move_button = $CanvasLayer/UI/BottomPanel/PlayerInfo/TicketButtons/DoubleMoveButton
@onready var history_log: Label = $CanvasLayer/UI/HistoryPanel/HistoryContainer/HistoryScroll/HistoryLog

@onready var anchor_program: AnchorProgram = $AnchorProgram

var graph = {}
var board_nodes = {}
var selected_node = -1
var selected_transport = -1  # 0=Taxi, 1=Bus, 2=Underground, 3=Black
var valid_moves = []

var _last_ai_turn_round := -1
var _last_ai_turn_index := -1
var _optimistic_mrx_turn := false  # true after AI move until chain confirms turn 0
var _ai_chain_active := false      # true while D1->D2->D3 chain; don't overwrite from chain

# ==================== PLAYER MARKERS ====================
var mr_x_marker: Node2D
var detective_markers: Array = []
var move_indicators: Array = []

# Marker colors
const MR_X_COLOR = Color(0.9, 0.1, 0.1)  # Red
const DETECTIVE_COLORS = [
	Color(0.2, 0.5, 1.0),   # Blue
	Color(0.2, 0.9, 0.3),   # Green
	Color(1.0, 0.7, 0.0)    # Orange/Yellow
]
const INDICATOR_COLOR = Color(0.0, 1.0, 1.0, 0.7)  # Cyan, semi-transparent
const INDICATOR_RING_COLOR = Color(1.0, 1.0, 1.0, 0.5)  # White ring

func _ready():
	_find_nodes()
	_load_graph()
	_connect_ticket_buttons()
	_create_markers()
	_update_ui()
	
	GlobalSolanaClient.game_updated.connect(_on_game_updated)
	GlobalSolanaClient.move_confirmed.connect(_on_move_confirmed)
	
	# Positions come from lobby (Mr. X) or game state (all). Don't overwrite.
	for i in range(3):
		GameManager.detective_positions[i] = 0
	
	if GameManager.is_mr_x:
		status_label.text = "You are Mr. X! Starting at node %d" % GameManager.mr_x_position
	else:
		var d = GameManager.my_detective_index
		if d >= 0:
			status_label.text = "You are Detective %d!" % (d + 1)
		else:
			status_label.text = "You are a Detective."
	
	ticket_buttons.visible = false
	_update_player_positions()
	_update_markers()
	_update_history()
	print("History log node: ", history_log)

# ==================== MARKER FUNCTIONS ====================

func _create_markers():
	# Create Mr. X marker (small to fit on nodes)
	mr_x_marker = _create_player_marker(MR_X_COLOR, 8, "X")
	mr_x_marker.visible = false
	mr_x_marker.z_index = 100
	add_child(mr_x_marker)
	
	# Create detective markers
	var labels = ["1", "2", "3"]
	for i in range(3):
		var marker = _create_player_marker(DETECTIVE_COLORS[i], 7, labels[i])
		marker.visible = false
		marker.z_index = 100
		add_child(marker)
		detective_markers.append(marker)

func _create_player_marker(color: Color, radius: float, label_text: String) -> Node2D:
	var marker = Node2D.new()
	
	# Create a custom draw node for the circle
	var circle = Node2D.new()
	circle.set_script(load("res://Script/marker_drawer.gd"))
	circle.set_meta("radius", radius)
	circle.set_meta("color", color)
	circle.set_meta("label", label_text)
	marker.add_child(circle)
	
	return marker

func _create_move_indicator() -> Node2D:
	var indicator = Node2D.new()
	indicator.z_index = 50
	
	var ring = Node2D.new()
	ring.set_script(load("res://Script/indicator_drawer.gd"))
	ring.set_meta("radius", 10.0)
	ring.set_meta("color", INDICATOR_COLOR)
	ring.set_meta("width", 2.0)
	indicator.add_child(ring)
	
	return indicator

func _update_markers():
	# Update Mr. X marker
	var show_mr_x = GameManager.is_mr_x or GameManager.is_reveal_round()
	if show_mr_x and GameManager.mr_x_position > 0:
		mr_x_marker.visible = true
		if board_nodes.has(GameManager.mr_x_position):
			mr_x_marker.global_position = board_nodes[GameManager.mr_x_position].global_position
	else:
		mr_x_marker.visible = false
	
	# On reveal rounds, show last revealed position for detectives
	if not GameManager.is_mr_x and GameManager.is_reveal_round():
		if GameManager.last_revealed_position > 0 and board_nodes.has(GameManager.last_revealed_position):
			mr_x_marker.visible = true
			mr_x_marker.global_position = board_nodes[GameManager.last_revealed_position].global_position
	
	# Update detective markers
	for i in range(min(detective_markers.size(), 3)):
		var pos = GameManager.detective_positions[i] if i < GameManager.detective_positions.size() else 0
		if pos > 0 and board_nodes.has(pos):
			detective_markers[i].visible = true
			detective_markers[i].global_position = board_nodes[pos].global_position
		else:
			detective_markers[i].visible = false

func _show_move_indicators(valid_node_ids: Array):
	_clear_move_indicators()
	
	for node_id in valid_node_ids:
		if board_nodes.has(node_id):
			var indicator = _create_move_indicator()
			add_child(indicator)
			indicator.global_position = board_nodes[node_id].global_position
			move_indicators.append(indicator)

func _clear_move_indicators():
	for indicator in move_indicators:
		if is_instance_valid(indicator):
			indicator.queue_free()
	move_indicators.clear()

# ==================== EXISTING FUNCTIONS ====================

func _find_nodes():
	for child in node_container.get_children():
		if child.has_method("set_highlight"):
			board_nodes[child.node_id] = child
			child.node_clicked.connect(_on_node_clicked)
	print("Found %d nodes" % board_nodes.size())

func _connect_ticket_buttons():
	taxi_button.pressed.connect(_on_taxi_selected)
	bus_button.pressed.connect(_on_bus_selected)
	underground_button.pressed.connect(_on_underground_selected)
	black_button.pressed.connect(_on_black_selected)
	double_move_button.pressed.connect(_on_double_move_selected)

func _on_taxi_selected():
	_select_transport(0)

func _on_bus_selected():
	_select_transport(1)

func _on_underground_selected():
	_select_transport(2)

func _on_black_selected():
	_select_transport(3)

func _on_double_move_selected():
	if GameManager.use_double_move():
		status_label.text = "Double Move activated! Make your first move."
		_update_ticket_buttons()
	else:
		status_label.text = "No double moves left!"

func _select_transport(transport: int):
	selected_transport = transport
	_clear_highlights()
	_clear_move_indicators()
	
	# Get moves for this transport type
	valid_moves = _get_moves_for_transport(selected_node, transport)
	
	print("Valid moves for transport ", transport, ": ", valid_moves)
	
	if valid_moves.is_empty():
		status_label.text = "No moves available with that ticket!"
		return
	
	# Get color based on transport
	var highlight_color = _get_transport_color(transport)
	
	# Highlight valid destinations
	for node_id in valid_moves:
		print("Highlighting node: ", node_id)
		if board_nodes.has(node_id):
			board_nodes[node_id].set_highlight(true, highlight_color)
		else:
			print("Node not found in board_nodes: ", node_id)
	
	# Show move indicators (rings)
	_show_move_indicators(valid_moves)
	
	status_label.text = "Click a highlighted node to move"

func _get_transport_color(transport: int) -> Color:
	match transport:
		0: return Color.YELLOW       # Taxi
		1: return Color.GREEN        # Bus
		2: return Color.RED          # Underground
		3: return Color.DARK_GRAY    # Black ticket
	return Color.WHITE

func _get_moves_for_transport(from_node: int, transport: int) -> Array:
	var moves = []
	if not graph.has(from_node):
		return moves
	
	for connection in graph[from_node]:
		var to_node = connection[0]
		var conn_transport = connection[1]
		
		# Black ticket can use any transport
		if transport == 3 or conn_transport == transport:
			# Check if destination is blocked
			if _is_valid_destination(to_node):
				if to_node not in moves:
					moves.append(to_node)
	
	return moves

func _bfs_distance(from_node: int, to_node: int) -> int:
	if from_node == to_node:
		return 0
	if not graph.has(from_node) or not graph.has(to_node):
		return 999
	var q: Array = [from_node]
	var dist := { from_node: 0 }
	while q.size() > 0:
		var cur: int = q.pop_front()
		var d: int = dist[cur]
		if not graph.has(cur):
			continue
		for conn in graph[cur]:
			var nxt: int = conn[0]
			if dist.has(nxt):
				continue
			dist[nxt] = d + 1
			if nxt == to_node:
				return d + 1
			q.append(nxt)
	return 999

# Get all nodes reachable within N steps from a position
func _get_reachable_nodes(from_node: int, max_steps: int) -> Array:
	var reachable := []
	var q: Array = [from_node]
	var dist := { from_node: 0 }
	while q.size() > 0:
		var cur: int = q.pop_front()
		var d: int = dist[cur]
		if d > 0:
			reachable.append(cur)
		if d >= max_steps:
			continue
		if not graph.has(cur):
			continue
		for conn in graph[cur]:
			var nxt: int = conn[0]
			if dist.has(nxt):
				continue
			dist[nxt] = d + 1
			q.append(nxt)
	return reachable

# Count how many neighbors a node has (escape routes)
func _count_escape_routes(node_id: int) -> int:
	if not graph.has(node_id):
		return 0
	var routes := 0
	for conn in graph[node_id]:
		var to_node: int = conn[0]
		# Don't count nodes occupied by detectives
		if to_node not in GameManager.detective_positions:
			routes += 1
	return routes

# Predict where Mr. X might be based on last known position and rounds passed
func _predict_mr_x_area() -> Array:
	var target: int = GameManager.last_revealed_position
	if target <= 0:
		return []
	
	# Calculate how many moves Mr. X could have made since last reveal
	var rounds_since_reveal := 0
	for r in GameManager.reveal_rounds:
		if r <= GameManager.round_number:
			rounds_since_reveal = GameManager.round_number - r
	
	# Mr. X could be anywhere within rounds_since_reveal + 1 moves
	var search_radius: int = mini(rounds_since_reveal + 2, 5)
	return _get_reachable_nodes(target, search_radius)

func _ai_pick_best_move(options: Array) -> Dictionary:
	if options.is_empty():
		return {}
	
	var di: int = GameManager.current_turn - 1
	var target: int = GameManager.last_revealed_position
	var mr_x_area: Array = _predict_mr_x_area()
	
	# Score each option
	var best: Dictionary = options[0]
	var best_score: float = -9999.0
	
	for opt in options:
		var to_node: int = opt["to"]
		var score: float = 0.0
		
		# === STRATEGY 1: Chase last known position ===
		if target > 0 and graph.has(target):
			var dist_to_target: int = _bfs_distance(to_node, target)
			# Closer is better (negative distance = higher score)
			score += (20 - dist_to_target) * 10.0
		
		# === STRATEGY 2: Cover predicted Mr. X area ===
		if mr_x_area.size() > 0:
			# Count how many predicted positions this move covers
			var coverage := 0
			for predicted_pos in mr_x_area:
				var dist: int = _bfs_distance(to_node, predicted_pos)
				if dist <= 2:
					coverage += 3 - dist  # Closer = more coverage points
			score += coverage * 5.0
		
		# === STRATEGY 3: Block escape routes ===
		# Prefer nodes that have many connections (hubs)
		var escape_routes: int = _count_escape_routes(to_node)
		score += escape_routes * 2.0
		
		# === STRATEGY 4: Spread out from other detectives ===
		var min_dist_to_ally := 999
		for i in range(GameManager.detective_count):
			if i == di:
				continue
			var ally_pos: int = GameManager.detective_positions[i]
			if ally_pos > 0:
				var dist: int = _bfs_distance(to_node, ally_pos)
				min_dist_to_ally = mini(min_dist_to_ally, dist)
		
		# Penalize being too close to allies (< 3 nodes)
		if min_dist_to_ally < 3:
			score -= (3 - min_dist_to_ally) * 8.0
		# Bonus for being at medium distance (good coverage)
		elif min_dist_to_ally >= 3 and min_dist_to_ally <= 5:
			score += 5.0
		
		# === STRATEGY 5: Prefer underground stations (fast travel) ===
		if graph.has(to_node):
			for conn in graph[to_node]:
				if conn[1] == 2:  # Underground connection
					score += 3.0
					break
		
		# === STRATEGY 6: Avoid corners (fewer escape options for detective) ===
		if escape_routes <= 2:
			score -= 5.0
		
		# === STRATEGY 7: Coordinate pincer movement ===
		# If another detective is close to target, approach from different angle
		if target > 0:
			for i in range(GameManager.detective_count):
				if i == di:
					continue
				var ally_pos: int = GameManager.detective_positions[i]
				if ally_pos > 0:
					var ally_dist: int = _bfs_distance(ally_pos, target)
					if ally_dist <= 3:
						# Ally is close to target, try to cut off escape
						var my_dist: int = _bfs_distance(to_node, target)
						if my_dist <= 4 and my_dist != ally_dist:
							score += 10.0  # Good flanking position
		
		# Small random factor to avoid predictability
		score += randf() * 2.0
		
		if score > best_score:
			best_score = score
			best = opt
	
	return best

func _is_valid_destination(to_node: int) -> bool:
	if GameManager.is_mr_x:
		# Mr. X can't move to detective positions
		return to_node not in GameManager.detective_positions
	else:
		# Detectives can't move to other detective positions
		var detective_index = GameManager.current_turn - 1
		for i in range(3):
			if i != detective_index and GameManager.detective_positions[i] == to_node:
				return false
		return true

func _on_node_clicked(node_id: int):
	if GameManager.game_over:
		return
	if GameManager.game_status == 0:
		# WaitingForPlayers: no moves until enough detectives join
		return
	
	print("Clicked node: ", node_id)
	
	# If we have a transport selected, try to move
	if selected_transport >= 0 and node_id in valid_moves:
		_execute_move(node_id)
		return
	
	# Otherwise, try to select position
	if GameManager.is_mr_x and GameManager.current_turn == 0:
		if node_id == GameManager.mr_x_position:
			_select_position(node_id)
	elif not GameManager.is_mr_x and GameManager.current_turn > 0:
		var detective_index = GameManager.current_turn - 1
		if detective_index != GameManager.my_detective_index:
			return  # Not our turn
		if node_id == GameManager.detective_positions[detective_index]:
			_select_position(node_id)

func _select_position(node_id: int):
	selected_node = node_id
	selected_transport = -1
	_clear_highlights()
	_clear_move_indicators()
	
	# Show ticket buttons with counts
	_update_ticket_buttons()
	ticket_buttons.visible = true
	status_label.text = "Select a ticket to use"

func _update_ticket_buttons():
	if GameManager.is_mr_x:
		taxi_button.text = "Taxi (%d)" % GameManager.mr_x_taxi
		bus_button.text = "Bus (%d)" % GameManager.mr_x_bus
		underground_button.text = "Underground (%d)" % GameManager.mr_x_underground
		black_button.text = "Black (%d)" % GameManager.mr_x_black
		double_move_button.text = "2x Move (%d)" % GameManager.mr_x_double_move
		
		taxi_button.disabled = GameManager.mr_x_taxi <= 0
		bus_button.disabled = GameManager.mr_x_bus <= 0
		underground_button.disabled = GameManager.mr_x_underground <= 0
		black_button.disabled = GameManager.mr_x_black <= 0
		black_button.visible = true
		
		# Only show double move if not already active
		double_move_button.visible = not GameManager.double_move_active
		double_move_button.disabled = GameManager.mr_x_double_move <= 0
	else:
		var di = GameManager.current_turn - 1
		taxi_button.text = "Taxi (%d)" % GameManager.detective_taxi[di]
		bus_button.text = "Bus (%d)" % GameManager.detective_bus[di]
		underground_button.text = "Underground (%d)" % GameManager.detective_underground[di]
		
		taxi_button.disabled = GameManager.detective_taxi[di] <= 0
		bus_button.disabled = GameManager.detective_bus[di] <= 0
		underground_button.disabled = GameManager.detective_underground[di] <= 0
		black_button.visible = false
		double_move_button.visible = false
	
	# Color the buttons
	taxi_button.modulate = Color.YELLOW
	bus_button.modulate = Color.GREEN
	underground_button.modulate = Color.RED
	black_button.modulate = Color.DARK_GRAY
	double_move_button.modulate = Color.PURPLE

func _execute_move(to_node: int):
	if GameManager.is_mr_x:
		_move_mr_x(to_node, selected_transport)
	else:
		var detective_index = GameManager.current_turn - 1
		_move_detective(to_node, detective_index, selected_transport)
	
	_clear_selection()

func _clear_selection():
	selected_node = -1
	selected_transport = -1
	valid_moves = []
	ticket_buttons.visible = false
	_clear_highlights()
	_clear_move_indicators()

func _clear_highlights():
	for node in board_nodes.values():
		node.set_highlight(false)

func _move_mr_x(to_node: int, transport: int):
	_optimistic_mrx_turn = false
	_ai_chain_active = false
	var use_black = (transport == 3)
	var from_node = GameManager.mr_x_position
	
	# Find actual transport type used (for black ticket)
	var actual_transport = transport
	if use_black:
		for connection in graph[GameManager.mr_x_position]:
			if connection[0] == to_node:
				actual_transport = connection[1]
				break
	
	GameManager.mr_x_use_ticket(actual_transport, use_black)
	GameManager.mr_x_position = to_node
	GameManager.mr_x_position_history.append(to_node)
	
	# Add to history
	GameManager.add_move_to_history("Mr. X", from_node, to_node, GameManager.last_mr_x_transport)
	_update_history()
	
	print("Mr. X moved to: ", to_node, " using ", GameManager.last_mr_x_transport)
	
	if GameManager.is_reveal_round():
		status_label.text = "REVEAL: Mr. X is at node " + str(to_node)
	else:
		status_label.text = "Mr. X moved using " + GameManager.last_mr_x_transport
	
	# Check if double move is active
	if GameManager.double_move_active:
		GameManager.finish_double_move_turn()
		if GameManager.double_move_remaining > 0:
			status_label.text = "Double Move! Make your second move."
			# Stay on Mr. X's turn - don't change current_turn
			_update_ui()
			_update_player_positions()
			_update_markers()
			return
	
	# Normal turn progression
	GameManager.current_turn = 1
	_skip_stuck_detectives()
	_check_win_conditions()
	
	# Vs AI: schedule detective move immediately (don't wait for poll)
	_maybe_schedule_ai_move()
	
	# Send to Solana (use actual_transport: 0–2 for taxi/bus/underground; API has 3=ferry)
	_send_move_to_solana(to_node, actual_transport)
	
	# Reveal on-chain when it's a reveal round (fire-and-forget)
	if GameManager.is_reveal_round():
		GameManager.last_revealed_position = to_node
		GlobalSolanaClient.reveal_mr_x(to_node)
	
	_update_ui()
	_update_player_positions()
	_update_markers()

func _move_detective(to_node: int, detective_index: int, transport: int):
	var from_node = GameManager.detective_positions[detective_index]
	
	# Use ticket (goes to Mr. X)
	var actual_transport = transport
	if transport == 3:
		# Find actual transport (shouldn't happen for detectives)
		for connection in graph[GameManager.detective_positions[detective_index]]:
			if connection[0] == to_node:
				actual_transport = connection[1]
				break
	
	GameManager.detective_use_ticket(detective_index, actual_transport)
	GameManager.detective_positions[detective_index] = to_node
	
	# Add to history
	var transport_names = ["Taxi", "Bus", "Underground", "Black"]
	GameManager.add_move_to_history("Detective " + str(detective_index + 1), from_node, to_node, transport_names[actual_transport])
	_update_history()
	
	print("Detective ", detective_index + 1, " moved to: ", to_node)
	
	# Check capture
	if to_node == GameManager.mr_x_position:
		GameManager.game_over = true
		GameManager.winner = "detectives"
		status_label.text = "DETECTIVES WIN! Mr. X captured at node " + str(to_node)
		_update_player_positions()
		_update_markers()
		_show_win_screen("detectives")
		return
	
	# Next turn
	GameManager.current_turn += 1
	if GameManager.current_turn > GameManager.detective_count:
		GameManager.current_turn = 0
		GameManager.round_number += 1
		
		if GameManager.round_number > GameManager.max_rounds:
			GameManager.game_over = true
			GameManager.winner = "mr_x"
			status_label.text = "MR. X WINS! Survived all rounds!"
			_update_player_positions()
			_update_markers()
			_show_win_screen("mr_x")
			return
	
	_skip_stuck_detectives()
	_check_win_conditions()
	
	# Send to Solana
	_send_move_to_solana(to_node, transport)
	
	_update_ui()
	_update_player_positions()
	_update_markers()

func _skip_stuck_detectives():
	while GameManager.current_turn > 0 and GameManager.current_turn <= GameManager.detective_count:
		var detective_index = GameManager.current_turn - 1
		if GameManager.detective_positions[detective_index] == 0:
			GameManager.current_turn += 1
		elif not GameManager.check_detective_can_move(detective_index):
			print("Detective ", detective_index + 1, " has no tickets, skipping")
			GameManager.current_turn += 1
		else:
			break
	
	if GameManager.current_turn > GameManager.detective_count:
		GameManager.current_turn = 0
		GameManager.round_number += 1

func _check_win_conditions():
	if GameManager.check_all_detectives_stuck():
		GameManager.game_over = true
		GameManager.winner = "mr_x"
		status_label.text = "MR. X WINS! All detectives out of tickets!"
		_show_win_screen("mr_x")
	
	if GameManager.check_mr_x_stuck():
		GameManager.game_over = true
		GameManager.winner = "detectives"
		status_label.text = "DETECTIVES WIN! Mr. X is stuck with no tickets!"
		_show_win_screen("detectives")

func _update_ui():
	round_label.text = "Round: %d / %d" % [GameManager.round_number, GameManager.max_rounds]
	
	if GameManager.game_status == 0:
		turn_label.text = "Waiting for players"
		ticket_buttons.visible = false
		mr_x_transport_label.text = "Mr. X used: %s" % GameManager.last_mr_x_transport
		_update_ticket_buttons()
		return
	
	if GameManager.current_turn == 0:
		turn_label.text = "Turn: Mr. X"
		if not GameManager.game_over:
			if GameManager.double_move_active and GameManager.double_move_remaining > 0:
				status_label.text = "Double Move! Move %d of 2" % (3 - GameManager.double_move_remaining)
			elif GameManager.is_mr_x:
				status_label.text = "Mr. X's turn - click your position"
			else:
				status_label.text = "Waiting for Mr. X to move..."
	else:
		turn_label.text = "Turn: Detective %d" % GameManager.current_turn
		if not GameManager.game_over:
			var di = GameManager.current_turn - 1
			if di == GameManager.my_detective_index:
				status_label.text = "Your turn! Click your position, pick a ticket, then move"
			else:
				status_label.text = "Waiting for Detective %d to move..." % GameManager.current_turn
	
	mr_x_transport_label.text = "Mr. X used: %s" % GameManager.last_mr_x_transport
	_update_ticket_buttons()

func _update_player_positions():
	var keep_valid_highlights := selected_node >= 0 and not valid_moves.is_empty()
	for node_id in board_nodes:
		var node = board_nodes[node_id]
		if keep_valid_highlights and node_id in valid_moves:
			continue
		node.set_highlight(false)
		node.set_player_color(Color.WHITE)
	
	# Highlight last move (from → to) so it's easy to see what just happened
	var last_from := GameManager.last_move_from
	var last_to := GameManager.last_move_to
	if last_from > 0 and board_nodes.has(last_from):
		board_nodes[last_from].set_highlight(true, Color.DARK_CYAN)
	if last_to > 0 and board_nodes.has(last_to):
		board_nodes[last_to].set_highlight(true, Color.CYAN)
	
	# Mr. X: only Mr. X sees his location during regular rounds; detectives see it only on reveal rounds
	if GameManager.is_mr_x:
		if board_nodes.has(GameManager.mr_x_position):
			board_nodes[GameManager.mr_x_position].set_player_color(Color.RED)
	else:
		if GameManager.is_reveal_round():
			var reveal_pos = GameManager.last_revealed_position
			if reveal_pos > 0 and board_nodes.has(reveal_pos):
				board_nodes[reveal_pos].set_player_color(Color.RED)
	
	# Detectives: bright, distinct colors so they're easy to see
	var detective_colors := [
		Color(0.2, 0.6, 1.0),   # Bright blue
		Color(0.2, 1.0, 0.4),   # Bright green
		Color(1.0, 0.55, 0.0),  # Orange
	]
	for i in range(3):
		var pos: int = GameManager.detective_positions[i]
		if pos > 0 and board_nodes.has(pos):
			board_nodes[pos].set_player_color(detective_colors[i])
			board_nodes[pos].set_highlight(true, detective_colors[i])

func _update_history():
	if history_log:
		var text = GameManager.get_history_text()
		print("History text: ", text)
		history_log.text = text
	else:
		print("history_log is null!")

func _load_graph():
	graph = {
		1: [[8,0], [58,1], [9,0], [46,1], [46,2]],
		2: [[20, 0], [10, 0]],
		3: [[11, 0], [22,1], [12, 0], [23,1], [4,0]],
		4: [[3, 0], [13, 0]],
		5: [[15,0], [16,0]],
		6: [[29,0], [7,0]],
		7: [[6,0], [17,0], [42,1]],
		8: [[1,0], [18,0], [19,0]],
		9: [[1,0], [19,0], [20,0]],
		10: [[2,0], [21,0], [11,0], [34,0]],
		11: [[10,0], [22,0], [3,0]],
		12: [[3,0], [23,0]],
		13: [[4,0], [23,0], [23,1], [46,2], [14,0], [14,1], [89,2], [24, 0], [52,1], [67,2]],
		14: [[13,0], [13,1], [15,0], [15,1], [25,0]],
		15: [[14,0], [14,1], [16,0], [26,0], [41,1], [5,0]],
		16: [[15,0], [29,0], [28,0], [5,0]],
		17: [[7,0], [30,0]],
		18: [[8,0], [31,0], [43,0]],
		19: [[8,0], [9,0], [32,0]],
		20: [[9,0], [2,0], [33,0]],
		21: [[33,0], [10,0]],
		22: [[11,0], [3,1], [35,0], [65,1], [34,0], [34,1], [46,2], [23,0], [23,1], [13,2]],
		23: [[22,0], [22,1], [13,0], [13,1], [12,0], [3,1], [37,0], [67,1]],
		24: [[13,0], [37,0], [38,0]],
		25: [[14,0], [38,0], [39,0]],
		26: [[15,0], [27,0], [39,0]],
		27: [[26,0], [28,0], [40,0]],
		28: [[27,0], [16,0], [41,0]],
		29: [[55,0], [55,1], [16,0], [16,1], [41,0], [41,1], [42,0], [42,1], [6,0]],
		30: [[17,0], [42,0]],
		31: [[18,0], [44,0], [43,0]],
		32: [[19,0], [44,0], [45,0], [33,0]],
		33: [[32,0], [20,0], [21,0], [46,0]],
		34: [[10,0], [47,0], [46,1], [22,0], [22,1], [48,0], [63,1]],
		35: [[48,0], [22,0], [65,0], [36,0]],
		36: [[35,0], [37,0], [49,0]],
		37: [[36,0], [24,0], [23,0], [50,0]],
		38: [[24,0], [25,0], [50,0], [51,0]],
		39: [[25,0], [52,0], [51,0], [26,0]],
		40: [[27,0], [41,0], [52,0], [53,0]],
		41: [[40,0], [52,1], [28,0], [15,1], [29,0], [29,1], [54,0], [87,1]],
		42: [[29,0], [29,1], [7,1], [56,0], [72,0], [72,1], [30,0]],
		43: [[18,0], [31,0], [57,0]],
		44: [[31,0], [32,0], [58,0]],
		45: [[32,0], [59,0], [58,0], [60,0], [46,0]],
		46: [[33,0], [1,1], [1,2], [45,0], [58,1], [74,2],[61,0], [78,1], [47,0], [34,1],[79,2]],
		47: [[46,0], [34,0], [62,0]],
		48: [[34,0], [35,0], [62,0], [63,0]],
		49: [[36,0], [50,0], [66,0]],
		50: [[49,0], [37,0], [38,0]],
		51: [[38,0], [39,0], [52,0], [67,0], [68,0]],
		52: [[51,0], [67,1], [39,0], [13,1], [40,0], [41,1], [69,0], [86,1]],
		53: [[40,0], [54,0], [69,0]],
		54: [[53,0], [55,0], [41,0], [70,0]],
		55: [[54,0], [29,1], [71,0], [89,1]],
		56: [[42,0], [91,0]],
		57: [[43,0], [73,0], [58,0]],
		58: [[57,0], [44,0], [1,1], [45,0], [46,1], [59,0], [77,1], [75,0], [74,0], [74,1]],
		59: [[45,0], [58,0], [75,0], [76,0]],
		60: [[45,0], [61,0], [76,0]],
		61: [[60,0], [76,0], [46,0],[62,0], [78,0]],
		62: [[61,0], [61,2], [47,0], [48,0], [79,0]],
		63: [[48,0], [34,1], [64,0], [65,1], [80,0], [100,1], [79,0], [79,1]],
		64: [[63,0], [65,0], [81,0]],
		65: [[64,0], [63,1], [35,0], [22,1], [66,0], [67,1], [82,0], [82,1]],
		66: [[65,0], [49,0], [67,0], [82,0]],
		67: [[66,0], [82,1], [79,2], [23,1], [13,2], [51,0], [52,1], [68,0], [89,2], [102,1], [65,1], [84,0], [111,2]],
		68: [[67,0], [51,0], [69,0], [85,0]],
		69: [[68,0], [52,0], [53,0], [86,0]],
		70: [[54,0], [71,0], [87,0]],
		71: [[70,0], [55,0], [72,0], [89,0]],
		72: [[71,0], [42,0], [42,1], [91,0], [107,1], [90,0], [105,1]],
		73: [[57,0], [74,0], [92,0]],
		74: [[73,0], [58,0], [58,1], [46,2], [75,0], [94,1], [92,0]],
		75: [[74,0], [58,0], [59,0], [94,0]],
		76: [[59,0], [60,0], [61,0], [77,0]],
		77: [[76,0], [58,1], [78,0], [78,1], [96,0], [124,1], [95,0], [94,1]],
		78: [[77,0], [77,1], [79,0], [79,1], [61,0], [46,1], [97,0]],
		79: [[78,0,2], [78,1], [93,2], [62,0], [46,2], [63,0], [63,1], [67,2], [98,0], [111,2]],
		80: [[63,0], [100,0], [99,0]],
		81: [[64,0], [82,0], [100,0]],
		82: [[81,0], [100,1], [65,0], [65,1], [66,0], [67,1], [140,1]],
		83: [[102,0], [101,0]],
		84: [[67,0], [85,0]],
		85: [[84, 0], [68,0], [103,0]],
		86: [[69,0], [52,1], [87,1], [104,0], [116,1], [103,0], [102,1]],
		87: [[87,1], [70,0], [41,1], [88,0], [105,1]],
		88: [[87,0], [89,0], [105,0], [117,0], [104,0]],
		89: [[88,0], [67,2], [13,2], [105,1], [105,0], [55,1], [71,0]],
		90: [[105,0], [72,0], [91,0]],
		91: [[90,0], [72,0], [56,0], [107,0], [105,0]],
		92: [[93,0],[73,0], [74,0]],
		93: [[92,0], [94,0], [94,1], [79,2]],
		94: [[93,0], [93,1], [74,1], [75,0], [95,0], [77,0]],
		95: [[94,0], [77,0], [122,0]],
		96: [[77,0], [97,0], [109,0]],
		97: [[96,0], [78,0], [98,0], [109,0]],
		98: [[97,0], [79,0], [99,0], [110,0]],
		99: [[98,0], [88,0], [110,0]],
		100: [[80,0], [63,1], [81,0], [82,1], [101,0], [113,0], [112, 0], [111,1]],
		101: [[100,0], [82,0], [83,0], [114,0]],
		102: [[83,0], [67,1], [103,0], [86,1], [115,0], [127,1]],
		103: [[102, 0], [85,0], [86,0]],
		104: [[86,0], [88,0], [116,0]],
		105: [[88,0], [87,1], [89,0], [89,1], [90,0], [72,1], [106,0], [118,0], [118,1]],
		106: [[105,0], [107,0]],
		107: [[106,0], [91,0], [72,0], [119,0], [161,1]],
		109: [[96,0], [97,0], [110,0], [124,0]],
		110: [[109,0], [98,0], [99,0], [111,0]],
		111: [[110,0], [112,0], [100,1], [153,2], [124,0], [124,1], [163,2]],
		112: [[111,0], [100,0], [125,0]],
		113: [[100,0], [114,0], [125,0]],
		114: [[113, 0], [101,0], [115,0], [126,0], [132,0],[131,0]],
		115: [[114,0], [102,0], [127,0], [126,0]],
		116: [[104,0], [86,1], [117,0], [118,1], [128,0], [142,1], [127,0], [127,1]],
		117: [[116,0], [88,0], [118,0], [129,0]],
		118: [[117,0], [116,1], [105,0], [105,1], [119,0], [135,1]],
		119: [[118,0], [107,0], [136,0]],
		120: [[121,0], [144,0]],
		121: [[120,0], [122,0], [145,0]],
		122: [[121,0], [144,1], [95,0], [123,0], [123,1], [146,0]],
		123: [[122,0], [122,1], [124,0], [124,1], [148,0], [149,0], [165,1]],
		124: [[123,0], [123,1], [109,0], [96,1], [111,0], [111,1], [130,0], [138,0], [138,1]],
		125: [[112,0], [113,0], [131,0]],
		126: [[114,0], [115,0], [140,0]],
		127: [[115,0], [102,1], [116,0], [116,1], [134,0], [133,0], [133,1]],
		128: [[116,0], [129,0], [142,0], [134,0]],
		129: [[117,0], [135,0], [142,0], [143,0], [128,0]],
		130: [[124,0], [131,0], [139,0]],
		131: [[130,0], [125,0], [114,0]],
		132: [[114,0], [140,0]],
		133: [[140,0], [140,1], [127,0], [127,1], [157,0], [141,0]],
		134: [[127,0], [128,0], [142,0], [141,0]],
		135: [[129,0], [118,1], [136,0], [161,0], [161,1], [143,0], [159,1]],
		136: [[135,0], [119,0], [162,0]],
		137: [[123,0], [147,0]],
		138: [[124,0], [152,0], [150,0]],
		139: [[130,0], [140,0], [153,0]],
		140: [[139,0], [132,0], [82,1], [126,0], [133,0], [133,1], [156,0], [156, 1], [89,2], [159,2], [153,2]],
		141: [[133,0], [134,0], [142,0], [158,0]],
		142: [[134,0], [128,0], [116,1], [129,0], [143,0], [159,0], [159,1], [158,0], [157,1], [141,0]],
		143: [[142,0], [129,0], [135,0], [160,0], [159,0]],
		144: [[120,0], [145,0], [122,1], [123,1], [163,1], [177,0]],
		145: [[144,0], [121,0], [146,0]],
		146: [[145,0], [122,0], [147,0], [163,0]],
		147: [[146,0], [137,0], [164,0]],
		148: [[164,0], [123,0], [149,0]],
		149: [[148,0], [123,0], [150,0], [165,0]],
		150: [[149,0], [138,0], [151,0]],
		151: [[150,0], [152,0], [166,0], [165,0]],
		152: [[151,0], [138,0], [153,0]],
		153: [[152,0], [124,1], [139,0], [111,2], [154,0], [154,1], [167,0], [184,1], [185,2], [166,0], [180,1], [163,2]],
		154: [[153,0], [153,1], [139,0], [140,0], [140,1], [155,0], [156,1]],
		155: [[154,0], [156,0], [168,0], [167,0]],
		156: [[155,0], [154,1], [140,0], [140,1], [157,0], [157,1], [169,0], [184,1]],
		157: [[156,1], [133,1], [142,1], [185,1], [156,0], [158,0], [170,0]],
		158: [[157,0], [141,0], [142,0], [171,0]],
		159: [[142,0], [142,1], [140,2], [143,0], [135,1], [89,2], [160,0], [161,1], [188,0], [199,1], [172,0], [187,1], [185,2]],
		160: [[159,0], [143,0], [161,0], [173,0]],
		161: [[160,0], [159,1], [135,0], [135,1], [136,1],[174,0], [199,1]],
		162: [[136,0], [175, 0]],
		163: [[144,1], [146,0], [111,2], [164,0], [153,2], [178,1], [177,0], [176,1]],
		164: [[163,0], [147,0], [148,0], [179,0], [178,0]],
		165: [[149,0], [151,0], [180,0], [180,1],[179,0], [191,1], [123,1]],
		166: [[151,0], [153,0], [183,0], [181,0]],
		167: [[153,0], [168,0], [183,0], [155,0]],
		168: [[167,0], [155,0], [184,0]],
		169: [[156,0], [184,0]],
		170: [[157,0], [171,0],[185,0]],
		171: [[170,0], [158,0], [172,0], [186,0]],
		172:[[171,0], [159,0], [187,0]],
		173: [[160,0], [174,0], [200,0], [188,0]],
		174: [[173,0], [161,0], [175,0]],
		175: [[174,0], [162,0], [200,0]],
		176: [[163,1], [177,0], [189,0], [190,1]],
		177: [[176,0], [144,0], [163,0]],
		178: [[189,0], [164,0], [191,0]],
		179: [[191,0], [164,0], [165,0]],
		180: [[165,0], [165,1], [181,0], [153,1], [193,0], [184,0]],
		181: [[180,0], [166,0], [182,0], [193,0]],
		182: [[181,0], [183,0], [195,0]],
		183: [[182,0], [166,0], [167,0], [184,0], [196,0]],
		184: [[183,0], [168,0], [153,0], [169,0], [156,1], [185,0], [185,1], [197,0], [196,0], [196,1]],
		185: [[184,0], [184,1], [153,2], [170,0], [157,1], [186,0], [187,1], [199,1], [159,2]],
		186: [[185,0], [171,0], [198,0]],
		187: [[159,1], [172,0], [198,0], [185,1], [199,1], [188,0]],
		188: [[187,0], [159,0], [173,0], [199,0]],
		189: [[176,0], [178,0], [190,0]],
		190: [[189,0], [176,1], [192,1], [191,1], [191,0]],
		191: [[190,0], [190,1], [178,0], [163,1], [165,1], [179,0], [192,0]],
		192: [[191,0], [194,0]],
		193: [[180,0], [181,0], [194,0]],
		194: [[193,0], [192,0], [195,0]],
		195: [[194,0], [182,0], [197,0]], 
		196: [[183,0], [184,0], [197,0]],
		197: [[196,0], [184,0], [195,0]],
		198: [[186,0], [187,0]],
		199: [[185,1], [188,0], [159,1], [200,0], [161,1]],
		200: [[199,0], [173,0], [175,0]]
	}

# ==================== SOLANA SYNC ====================

func _on_game_updated(game_state: Dictionary):
	if game_state.is_empty():
		return
	
	print("Game state updated from Solana")
	
	var chain_turn: int = game_state.current_turn
	var chain_positions: Array = game_state.detective_positions
	
	# Don't overwrite optimistic Mr. X turn with stale "detective turn" from chain
	if _optimistic_mrx_turn:
		if chain_turn == 0:
			_optimistic_mrx_turn = false
		elif chain_turn >= 1:
			chain_turn = 0
			chain_positions = [GameManager.detective_positions[0], GameManager.detective_positions[1], GameManager.detective_positions[2]]
	
	# Don't overwrite turn/positions while AI chain (D1->D2->D3) in progress
	var keep_local_round := false
	if _ai_chain_active:
		chain_turn = GameManager.current_turn
		chain_positions = [GameManager.detective_positions[0], GameManager.detective_positions[1], GameManager.detective_positions[2]]
		keep_local_round = true
	if _optimistic_mrx_turn and chain_turn >= 1:
		keep_local_round = true
	
	# Update detective positions
	for i in range(3):
		GameManager.detective_positions[i] = chain_positions[i] if i < chain_positions.size() else 0
	
	# Update turn, round, detective count, status
	GameManager.current_turn = chain_turn
	var chain_round: int = game_state.round
	if not keep_local_round:
		# Never decrease round from chain (it lags); only advance or keep local
		if chain_round > GameManager.round_number:
			GameManager.round_number = chain_round
	GameManager.detective_count = game_state.get("detective_count", 3)
	GameManager.max_detectives = game_state.get("max_detectives", 3)
	var chain_status: int = game_state.get("status", 1)
	# Vs AI: we've already joined the AI; chain may still say WaitingForPlayers until join confirms
	if GameManager.vs_ai and chain_status == 0:
		GameManager.game_status = 1
		if GameManager.detective_count <= 0 and GameManager.max_detectives >= 1:
			GameManager.detective_count = 1
	else:
		GameManager.game_status = chain_status
	
	# Update Mr. X last transport
	var transport_names = ["None", "Taxi", "Bus", "Underground", "Ferry"]
	GameManager.last_mr_x_transport = transport_names[game_state.mr_x_last_transport]
	
	# Update revealed position if available
	if game_state.last_revealed_position > 0:
		GameManager.last_revealed_position = game_state.last_revealed_position
	
	# Check game status
	match game_state.status:
		0:  # WaitingForPlayers
			var need = GameManager.max_detectives - GameManager.detective_count
			var msg = "Waiting for %d more detective(s) to join" % need
			if need <= 0:
				msg = "All detectives joined — game starting..."
			status_label.text = msg
		2:  # MrXWins
			GameManager.game_over = true
			GameManager.winner = "mr_x"
			status_label.text = "MR. X WINS!"
		3:  # DetectivesWin
			GameManager.game_over = true
			GameManager.winner = "detectives"
			status_label.text = "DETECTIVES WIN!"
	
	_update_ui()
	_update_player_positions()
	_update_markers()
	_maybe_schedule_ai_move()

func _maybe_schedule_ai_move() -> void:
	if GameManager.game_over:
		return
	if not GameManager.vs_ai or not GameManager.is_mr_x or GameManager.game_status != 1:
		return
	if GameManager.current_turn < 1 or GameManager.current_turn > GameManager.detective_count:
		return
	if GameManager.round_number == _last_ai_turn_round and GameManager.current_turn == _last_ai_turn_index:
		return
	_last_ai_turn_round = GameManager.round_number
	_last_ai_turn_index = GameManager.current_turn
	_ai_chain_active = true
	_schedule_ai_move()

func _schedule_ai_move() -> void:
	# 2s delay to let previous move confirm on-chain before next detective
	await get_tree().create_timer(2.0).timeout
	_ai_detective_move()

func _ai_detective_move() -> void:
	var di: int = GameManager.current_turn - 1
	var pos: int = GameManager.detective_positions[di]
	if pos <= 0:
		_try_skip_stuck_and_schedule_next_ai()
		return
	var options: Array = []
	var transport_names := ["Taxi", "Bus", "Underground"]
	for t in range(3):
		if not GameManager.detective_has_ticket(di, t):
			continue
		var moves := _get_moves_for_transport(pos, t)
		for to_node in moves:
			options.append({"to": to_node, "transport": t})
	if options.is_empty():
		print("AI Detective %d stuck (no valid moves), skipping" % (di + 1))
		_try_skip_stuck_and_schedule_next_ai()
		return
	var pick: Dictionary = _ai_pick_best_move(options)
	var to_node: int = pick["to"]
	var transport: int = pick["transport"]
	GameManager.detective_use_ticket(di, transport)
	GameManager.detective_positions[di] = to_node
	GameManager.add_move_to_history("Detective %d" % (di + 1), pos, to_node, transport_names[transport])
	# Check capture
	if to_node == GameManager.mr_x_position:
		GameManager.game_over = true
		GameManager.winner = "detectives"
		_ai_chain_active = false
		status_label.text = "DETECTIVES WIN! Mr. X captured at node %d" % to_node
		GlobalSolanaClient.move_detective(di, to_node, transport)
		_update_ui()
		_update_player_positions()
		_update_markers()
		_update_history()
		_show_win_screen("detectives")
		return
	# Turn progression: next detective or wrap to Mr. X
	GameManager.current_turn += 1
	if GameManager.current_turn > GameManager.detective_count:
		GameManager.current_turn = 0
		GameManager.round_number += 1
		_optimistic_mrx_turn = true
		_ai_chain_active = false
		if GameManager.round_number > GameManager.max_rounds:
			GameManager.game_over = true
			GameManager.winner = "mr_x"
			status_label.text = "MR. X WINS! Survived all rounds!"
			_show_win_screen("mr_x")
		else:
			status_label.text = "AI Detective %d moved to %d (%s) — Your turn!" % [di + 1, to_node, transport_names[transport]]
	else:
		status_label.text = "AI Detective %d moved to %d (%s)" % [di + 1, to_node, transport_names[transport]]
	_skip_stuck_detectives()
	_check_win_conditions()
	GlobalSolanaClient.move_detective(di, to_node, transport)
	_update_ui()
	_update_player_positions()
	_update_markers()
	_update_history()
	# Chain to next AI detective if still their turn (e.g. D1 -> D2 -> D3)
	_maybe_schedule_ai_move()

func _try_skip_stuck_and_schedule_next_ai() -> void:
	GameManager.current_turn += 1
	if GameManager.current_turn > GameManager.detective_count:
		GameManager.current_turn = 0
		GameManager.round_number += 1
		_optimistic_mrx_turn = true
		_ai_chain_active = false
		if GameManager.round_number > GameManager.max_rounds:
			GameManager.game_over = true
			GameManager.winner = "mr_x"
			status_label.text = "MR. X WINS! Survived all rounds!"
			_show_win_screen("mr_x")
	_skip_stuck_detectives()
	_check_win_conditions()
	_update_ui()
	_update_player_positions()
	_update_markers()
	_maybe_schedule_ai_move()

func _on_move_confirmed():
	print("Move confirmed on Solana")
	_update_ui()
	_update_player_positions()
	_update_markers()

func _send_move_to_solana(to_node: int, transport: int):
	if GameManager.is_mr_x:
		if OS.has_feature("web"):
			var encrypted_pos = await GlobalSolanaClient.encrypt_position(to_node)
			GlobalSolanaClient.move_mr_x(encrypted_pos, transport)
		else:
			# Desktop test: pass position, API encrypts server-side
			GlobalSolanaClient.move_mr_x(to_node, transport)
	else:
		var detective_index = GameManager.current_turn - 1
		GlobalSolanaClient.move_detective(detective_index, to_node, transport)

# ==================== WIN SCREEN ====================

var win_screen: CanvasLayer = null

func _show_win_screen(winner: String):
	if win_screen != null:
		return  # Already showing
	
	win_screen = CanvasLayer.new()
	win_screen.layer = 200
	add_child(win_screen)
	
	# Dark overlay
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.85)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	win_screen.add_child(overlay)
	
	# Center container
	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	win_screen.add_child(center)
	
	# Main panel
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.border_color = Color(0.3, 0.3, 0.4)
	style.set_border_width_all(3)
	style.set_corner_radius_all(20)
	style.set_content_margin_all(40)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	
	# Content
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 30)
	panel.add_child(vbox)
	
	# Winner title
	var title = Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if winner == "mr_x":
		if GameManager.is_mr_x:
			title.text = "🎉 VICTORY! 🎉"
			title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		else:
			title.text = "💀 DEFEAT 💀"
			title.add_theme_color_override("font_color", Color(0.8, 0.2, 0.2))
	else:
		if GameManager.is_mr_x:
			title.text = "💀 CAPTURED! 💀"
			title.add_theme_color_override("font_color", Color(0.8, 0.2, 0.2))
		else:
			title.text = "🎉 VICTORY! 🎉"
			title.add_theme_color_override("font_color", Color(0.2, 0.8, 0.4))
	title.add_theme_font_size_override("font_size", 48)
	vbox.add_child(title)
	
	# Winner subtitle
	var subtitle = Label.new()
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if winner == "mr_x":
		subtitle.text = "MR. X WINS!"
		subtitle.add_theme_color_override("font_color", Color(0.9, 0.1, 0.1))
	else:
		subtitle.text = "DETECTIVES WIN!"
		subtitle.add_theme_color_override("font_color", Color(0.2, 0.6, 1.0))
	subtitle.add_theme_font_size_override("font_size", 32)
	vbox.add_child(subtitle)
	
	# Stats
	var stats = Label.new()
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.text = "Round: %d / %d" % [GameManager.round_number, GameManager.max_rounds]
	stats.add_theme_font_size_override("font_size", 20)
	stats.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(stats)
	
	# Reason
	var reason = Label.new()
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.add_theme_font_size_override("font_size", 18)
	reason.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	if winner == "mr_x":
		if GameManager.round_number > GameManager.max_rounds:
			reason.text = "Mr. X survived all rounds!"
		elif GameManager.check_all_detectives_stuck():
			reason.text = "All detectives ran out of tickets!"
		else:
			reason.text = "Mr. X escaped!"
	else:
		if GameManager.check_mr_x_stuck():
			reason.text = "Mr. X ran out of tickets!"
		else:
			reason.text = "Mr. X was captured at node %d!" % GameManager.mr_x_position
	vbox.add_child(reason)
	
	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)
	
	# Buttons container
	var buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 20)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(buttons)
	
	# Play Again button
	var play_again_btn = Button.new()
	play_again_btn.text = "Play Again"
	play_again_btn.custom_minimum_size = Vector2(150, 50)
	play_again_btn.add_theme_font_size_override("font_size", 18)
	play_again_btn.pressed.connect(_on_play_again)
	buttons.add_child(play_again_btn)
	
	# Main Menu button
	var menu_btn = Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.custom_minimum_size = Vector2(150, 50)
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.pressed.connect(_on_main_menu)
	buttons.add_child(menu_btn)

func _on_play_again():
	if win_screen:
		win_screen.queue_free()
		win_screen = null
	GameManager.reset()
	get_tree().change_scene_to_file("res://Scene/lobby.tscn")

func _on_main_menu():
	if win_screen:
		win_screen.queue_free()
		win_screen = null
	GameManager.reset()
	get_tree().change_scene_to_file("res://Scene/main_menu.tscn")
