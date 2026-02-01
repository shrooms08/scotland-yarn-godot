extends Control

@onready var create_button = $VBoxContainer/CreateGameButton
@onready var max_detectives_option = $VBoxContainer/MaxDetectivesOption
@onready var max_detectives_value = $VBoxContainer/MaxDetectivesValue
@onready var join_button = $VBoxContainer/JoinGameButton
@onready var game_pda_input = $VBoxContainer/GamePdaInput
@onready var create_popup = $CreatePopup
@onready var create_popup_pda_label = $CreatePopup/VBox/PdaLabel
@onready var create_popup_copy_btn = $CreatePopup/VBox/CopyButton
@onready var create_popup_continue_btn = $CreatePopup/VBox/ContinueButton

var _pending_game_id = ""
var _pending_game_pda = ""
var _create_max_det := 3

func _ready():
	GameManager.reset()
	create_button.pressed.connect(_on_create_game_pressed)
	join_button.pressed.connect(_on_join_game_pressed)
	#if max_detectives_option:
		#max_detectives_option.item_selected.connect(_on_max_detectives_changed)
		#_update_detectives_label()
	GlobalSolanaClient.game_created.connect(_on_game_created)
	GlobalSolanaClient.game_joined.connect(_on_game_joined)
	GlobalSolanaClient.error_occurred.connect(_on_error)
	if create_popup:
		create_popup.visible = false
		if create_popup_continue_btn:
			create_popup_continue_btn.pressed.connect(_on_create_continue_pressed)
		if create_popup_copy_btn:
			create_popup_copy_btn.pressed.connect(_on_create_copy_pressed)

#func _update_detectives_label():
	#var n := 3
	#if max_detectives_option:
		#var idx = max_detectives_option.selected
		#if idx >= 0:
			#var id_val = max_detectives_option.get_item_id(idx)
			#if id_val >= 1 and id_val <= 3:
				#n = id_val
	#if max_detectives_value:
		#max_detectives_value.text = "Playing with %d detective%s" % [n, "s" if n != 1 else ""]

#func _on_max_detectives_changed(_index: int):
	#_update_detectives_label()

func _on_create_game_pressed():
	AudioManager.play_button_click()
	GameManager.is_mr_x = true
	var game_id = randi() % 1000000
	var start_pos = GameManager.draw_starting_position(true)
	GameManager.mr_x_position = start_pos
	GameManager.mr_x_position_history.append(start_pos)
	var max_det := 3
	if max_detectives_option:
		var idx = max_detectives_option.selected
		if idx >= 0:
			var id_val = max_detectives_option.get_item_id(idx)
			if id_val >= 1 and id_val <= 3:
				max_det = id_val
	_create_max_det = max_det
	print("Creating game: ", game_id, " at position: ", start_pos, " max_detectives=", max_det)
	create_button.disabled = true
	if OS.has_feature("web"):
		var encrypted_pos = await GlobalSolanaClient.encrypt_position(start_pos)
		GlobalSolanaClient.create_game(game_id, encrypted_pos, max_det, 5, 24)
	else:
		# Desktop test mode: pass position, API encrypts server-side
		GlobalSolanaClient.create_game(game_id, start_pos, max_det, 5, 24)
	create_button.disabled = false

func _on_join_game_pressed():
	AudioManager.play_button_click()
	var game_pda = game_pda_input.text.strip_edges()
	if game_pda.is_empty():
		print("Please paste the Game PDA from the creator")
		return
	GameManager.is_mr_x = false
	GameManager.game_id = game_pda
	var start_pos = GameManager.draw_starting_position(false)
	print("Joining game at PDA: ", game_pda, " at position: ", start_pos)
	GlobalSolanaClient.join_game(game_pda, start_pos)

func _on_game_created(game_id, game_pda):
	print("Game created! ID: ", game_id, " PDA: ", game_pda)
	GameManager.game_id = str(game_id)
	GlobalSolanaClient.current_game_pda = game_pda
	_pending_game_id = str(game_id)
	_pending_game_pda = str(game_pda)
	await _add_ai_detectives_and_show_popup(game_pda)

func _add_ai_detectives_and_show_popup(game_pda: String) -> void:
	var n := _create_max_det
	for i in range(n):
		var ai_start := GameManager.draw_starting_position(false)
		var join_resp := await GlobalSolanaClient.join_as_ai(game_pda, ai_start)
		if join_resp.is_empty() or not join_resp.has("detective_index"):
			_on_error("AI detective %d join failed" % (i + 1))
			_show_create_popup()
			return
	GameManager.vs_ai = true
	GameManager.detective_count = n
	if create_popup_pda_label:
		create_popup_pda_label.text = "Vs AI (%d detectives)! " % n + _pending_game_pda
	_show_create_popup()

func _show_create_popup() -> void:
	if create_popup:
		if create_popup_pda_label and not GameManager.vs_ai:
			create_popup_pda_label.text = _pending_game_pda
		create_popup.visible = true
	else:
		_start_polling_and_go_to_board()

func _on_create_continue_pressed():
	AudioManager.play_button_click()
	_start_polling_and_go_to_board()

func _on_create_copy_pressed():
	AudioManager.play_button_click()
	if _pending_game_pda.is_empty():
		return
	DisplayServer.clipboard_set(_pending_game_pda)
	if create_popup_copy_btn:
		create_popup_copy_btn.text = "Copied!"

func _start_polling_and_go_to_board():
	GlobalSolanaClient.start_polling()
	get_tree().change_scene_to_file("res://Scene/game_board.tscn")

func _on_game_joined(detective_index):
	# API returns 1-based index; we store 0-based.
	GameManager.my_detective_index = detective_index - 1
	if GameManager.my_detective_index < 0:
		GameManager.my_detective_index = 0
	print("Joined game as Detective ", GameManager.my_detective_index + 1)
	GlobalSolanaClient.start_polling()
	get_tree().change_scene_to_file("res://Scene/game_board.tscn")

func _on_error(message):
	print("Error: ", message)
