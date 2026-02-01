extends Node

# Player state
var is_mr_x := false
var game_id := ""
var player_wallet := ""
var my_detective_index := -1  # 0–2 when joined as detective; -1 otherwise

# Game state
var current_turn := 0  # 0 = Mr. X, 1–3 = detectives
var detective_count := 3  # from chain; used for turn wrap
var max_detectives := 3  # from chain; 1–3
var game_status := 1  # 0=WaitingForPlayers, 1=Active, 2=MrXWins, 3=DetectivesWin, 4=Cancelled
var last_revealed_position := 0  # Mr. X position after last reveal (for detectives)
var round_number := 1
var max_rounds := 24
var reveal_rounds := [3, 8, 13, 18, 24]  # Classic Scotland Yard reveal rounds

# Positions
var mr_x_position := 0
var mr_x_position_history := []  # Track all positions for reveal
var detective_positions := [0, 0, 0]
var last_mr_x_transport := ""

# Mr. X tickets
var mr_x_taxi := 10
var mr_x_bus := 8
var mr_x_underground := 6
var mr_x_black := 2  # Wild card - hides transport type
var mr_x_double_move := 1  # Take 2 turns in a row

# Add these new variables
var double_move_active := false
var double_move_remaining := 0

# Detective tickets (each detective)
var detective_taxi := [10, 10, 10]
var detective_bus := [8, 8, 8]
var detective_underground := [4, 4, 4]

# Game status
var game_over := false
var winner := ""  # "mr_x" or "detectives"
var vs_ai := false  # true when playing vs AI detective (1 detective, auto-join)

# Starting position cards
var mr_x_start_positions := [35, 45, 51, 71, 78, 104, 106, 127, 132, 146, 166, 170, 172]
var detective_start_positions := [13, 26, 29, 34, 50, 53, 91, 94, 103, 112, 117, 123, 138, 141, 155, 174]

# Move history
var move_history := []
var last_move_from := 0
var last_move_to := 0

func reset():
	is_mr_x = false
	game_id = ""
	my_detective_index = -1
	last_revealed_position = 0
	detective_count = 3
	max_detectives = 3
	game_status = 1
	current_turn = 0
	round_number = 1
	game_over = false
	winner = ""
	vs_ai = false
	
	mr_x_position = 0
	mr_x_position_history = []
	detective_positions = [0, 0, 0]
	last_mr_x_transport = ""
	
	# Reset Mr. X tickets
	mr_x_taxi = 10
	mr_x_bus = 8
	mr_x_underground = 6
	mr_x_black = 2
	mr_x_double_move = 1
	
	# Reset detective tickets
	detective_taxi = [10, 10, 10]
	detective_bus = [8, 8, 8]
	detective_underground = [4, 4, 4]
	
	# Reset starting positions
	mr_x_start_positions = [35, 45, 51, 71, 78, 104, 106, 127, 132, 146, 166, 170, 172]
	detective_start_positions = [13, 26, 29, 34, 50, 53, 91, 94, 103, 112, 117, 123, 138, 141, 155, 174]
	
	double_move_active = false
	double_move_remaining = 0
	
	move_history = []
	last_move_from = 0
	last_move_to = 0

func draw_starting_position(is_mr_x_player: bool) -> int:
	if is_mr_x_player:
		var index = randi() % mr_x_start_positions.size()
		return mr_x_start_positions[index]
	else:
		var index = randi() % detective_start_positions.size()
		var position = detective_start_positions[index]
		# Remove so other detectives can't get same position
		detective_start_positions.remove_at(index)
		return position

func mr_x_has_ticket(transport: int, use_black: bool = false) -> bool:
	if use_black:
		return mr_x_black > 0
	match transport:
		0: return mr_x_taxi > 0
		1: return mr_x_bus > 0
		2: return mr_x_underground > 0
	return false

func mr_x_use_ticket(transport: int, use_black: bool = false):
	if use_black:
		mr_x_black -= 1
		last_mr_x_transport = "Black"
	else:
		match transport:
			0:
				mr_x_taxi -= 1
				last_mr_x_transport = "Taxi"
			1:
				mr_x_bus -= 1
				last_mr_x_transport = "Bus"
			2:
				mr_x_underground -= 1
				last_mr_x_transport = "Underground"

func detective_has_ticket(detective_index: int, transport: int) -> bool:
	match transport:
		0: return detective_taxi[detective_index] > 0
		1: return detective_bus[detective_index] > 0
		2: return detective_underground[detective_index] > 0
	return false

func detective_use_ticket(detective_index: int, transport: int):
	# Detective uses ticket (Mr. X does not receive used tickets)
	match transport:
		0:
			detective_taxi[detective_index] -= 1
		1:
			detective_bus[detective_index] -= 1
		2:
			detective_underground[detective_index] -= 1

func is_reveal_round() -> bool:
	return round_number in reveal_rounds

func check_detective_can_move(detective_index: int) -> bool:
	# Check if detective has any tickets left
	return detective_taxi[detective_index] > 0 or \
		   detective_bus[detective_index] > 0 or \
		   detective_underground[detective_index] > 0

func check_all_detectives_stuck() -> bool:
	for i in range(detective_count):
		if detective_positions[i] > 0 and check_detective_can_move(i):
			return false
	return true

func check_mr_x_stuck() -> bool:
	# Mr. X is stuck if no tickets left
	return mr_x_taxi <= 0 and mr_x_bus <= 0 and mr_x_underground <= 0 and mr_x_black <= 0

func use_double_move() -> bool:
	if mr_x_double_move > 0:
		mr_x_double_move -= 1
		double_move_active = true
		double_move_remaining = 2  # Mr. X gets 2 moves
		return true
	return false

func finish_double_move_turn():
	double_move_remaining -= 1
	if double_move_remaining <= 0:
		double_move_active = false

func add_move_to_history(player: String, from_node: int, to_node: int, transport: String):
	last_move_from = from_node
	last_move_to = to_node
	var move = {
		"round": round_number,
		"player": player,
		"from": from_node,
		"to": to_node,
		"transport": transport
	}
	move_history.append(move)
	print("Added to history: ", move)

func get_history_text() -> String:
	var text = ""
	for move in move_history:
		if move.player == "Mr. X":
			# Show position on reveal rounds, otherwise just transport
			if move.round in reveal_rounds:
				text += "R%d: Mr. X at NODE %d (%s) [REVEAL]\n" % [move.round, move.to, move.transport]
			else:
				text += "R%d: Mr. X used %s\n" % [move.round, move.transport]
		else:
			text += "R%d: %s: %d → %d (%s)\n" % [move.round, move.player, move.from, move.to, move.transport]
	return text
