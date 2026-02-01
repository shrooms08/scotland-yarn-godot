extends Node

const PROGRAM_ID = "CDCd6YhgMBQtKvaUvD2HB9hAGKxJeWMr9AvQmsjYsKok"
const RPC_URL = "https://api.devnet.solana.com"
const BASE_URL = "http://localhost:3000"  # default API URL; override via set_base_url() for 2-laptop play

# On desktop there is no Phantom. Use test endpoints (create-test, join-test, etc.) — no signing.
const DESKTOP_TEST_SIGNATURE := "desktop_test_signature"

signal game_created(game_id, game_pda)
signal game_joined(detective_index)
signal game_updated(game_state)
signal move_confirmed()
signal error_occurred(message)

var http_request: HTTPRequest
var current_wallet: String = ""
var current_game_pda: String = ""
var base_url: String = BASE_URL
var polling_timer: Timer
var pending_request_type: String = ""  # Track which request is in progress

func set_base_url(url: String) -> void:
	var s := url.strip_edges()
	base_url = s if s.length() > 0 else BASE_URL

func _ready():
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)
	
	# Timer for polling game state
	polling_timer = Timer.new()
	polling_timer.wait_time = 3.0  # Poll every 3 seconds
	polling_timer.timeout.connect(_poll_game_state)
	add_child(polling_timer)

func set_wallet(wallet_pubkey: String):
	current_wallet = wallet_pubkey
	print("Wallet set: ", wallet_pubkey)

# ==================== GAME ACTIONS ====================

func create_game(game_id: int, encrypted_position_or_position, max_detectives: int = 3, rounds_between_reveals: int = 3, max_rounds: int = 24):
	print("Creating game with ID: ", game_id)
	
	if _use_test_endpoints():
		# Desktop / no Phantom: send plain position — API encrypts server-side (avoids serialization issues).
		var body := {
			"position": encrypted_position_or_position if typeof(encrypted_position_or_position) == TYPE_INT else int(encrypted_position_or_position),
			"game_id": game_id,
			"max_detectives": max_detectives,
			"rounds_between_reveals": rounds_between_reveals,
			"max_rounds": max_rounds,
		}
		var create_response := await _post_json(base_url + "/api/game/create-test", body)
		if create_response.is_empty():
			return ""
		if not create_response.has("game_id") or not create_response.has("game_pda"):
			emit_signal("error_occurred", "Invalid response from create game")
			return ""
		current_game_pda = create_response.game_pda
		GameManager.game_id = str(create_response.game_id)
		emit_signal("game_created", create_response.game_id, create_response.game_pda)
		return current_game_pda
	
	if current_wallet.is_empty():
		emit_signal("error_occurred", "Wallet not set")
		return ""
	
	# Web: intent flow (Phantom signs message)
	var intent_body := {
		"wallet": current_wallet,
		"action": "create_game",
		"encrypted_position": encrypted_position_or_position,
		"max_detectives": max_detectives,
	}
	var intent_response := await _post_json(base_url + "/api/game/intent", intent_body)
	if intent_response.is_empty():
		return ""
	if not intent_response.has("intent_id") or not intent_response.has("message"):
		emit_signal("error_occurred", "Invalid intent response for create_game")
		return ""
	var intent_id = intent_response.intent_id
	var message: String = str(intent_response.message)
	var signature := await _get_signature_for_message(message)
	if signature.is_empty():
		emit_signal("error_occurred", "Message signing failed or was cancelled")
		return ""
	var create_body := {
		"wallet": current_wallet,
		"intent_id": intent_id,
		"signature": signature,
		"encrypted_position": encrypted_position_or_position,
	}
	var create_response := await _post_json(base_url + "/api/game/create", create_body)
	if create_response.is_empty():
		return ""
	if not create_response.has("game_id") or not create_response.has("game_pda"):
		emit_signal("error_occurred", "Invalid response from create game")
		return ""
	current_game_pda = create_response.game_pda
	GameManager.game_id = str(create_response.game_id)
	emit_signal("game_created", create_response.game_id, create_response.game_pda)
	return current_game_pda

func join_game(game_pda: String, starting_position: int):
	print("Joining game at: ", game_pda, " with position: ", starting_position)
	current_game_pda = game_pda
	
	if _use_test_endpoints():
		var body := {"game_pda": game_pda, "starting_position": starting_position}
		var json_body := JSON.stringify(body)
		var headers := ["Content-Type: application/json"]
		pending_request_type = "join_game"
		var err := http_request.request(base_url + "/api/game/join-test", headers, HTTPClient.METHOD_POST, json_body)
		if err != OK:
			emit_signal("error_occurred", "Failed to send join game request")
			pending_request_type = ""
		return
	
	if current_wallet.is_empty():
		emit_signal("error_occurred", "Wallet not set")
		return
	
	var body = {
		"game_pda": game_pda,
		"wallet": current_wallet,
		"starting_position": starting_position
	}
	var json_body = JSON.stringify(body)
	var headers = ["Content-Type: application/json"]
	var url = base_url + "/api/game/join"
	pending_request_type = "join_game"
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		emit_signal("error_occurred", "Failed to send join game request")
		pending_request_type = ""

## Call join-test to add AI as detective. No signals, no role change. Returns JSON dict or {}.
func join_as_ai(game_pda: String, starting_position: int) -> Dictionary:
	if game_pda.is_empty():
		return {}
	var body := {"game_pda": game_pda, "starting_position": starting_position}
	return await _post_json(base_url + "/api/game/join-test", body)

func move_mr_x(new_encrypted_position_or_position, transport: int):
	print("Mr. X moving with transport: ", transport)
	
	if current_game_pda.is_empty():
		emit_signal("error_occurred", "Game PDA not set")
		return
	if not _use_test_endpoints() and current_wallet.is_empty():
		emit_signal("error_occurred", "Wallet not set")
		return
	
	if _use_test_endpoints():
		var move_body := {
			"game_pda": current_game_pda,
			"position": new_encrypted_position_or_position if typeof(new_encrypted_position_or_position) == TYPE_INT else int(new_encrypted_position_or_position),
			"transport": transport,
		}
		var move_response := await _post_json(base_url + "/api/game/move/mrx-test", move_body)
		if move_response.is_empty():
			return
		if move_response.get("success", false):
			emit_signal("move_confirmed")
		else:
			emit_signal("error_occurred", move_response.get("error", "Move Mr. X failed"))
		return
	
	# Web: intent flow (caller must pass encrypted array)
	var encrypted_pos = new_encrypted_position_or_position
	if typeof(encrypted_pos) != TYPE_ARRAY:
		encrypted_pos = await encrypt_position(int(new_encrypted_position_or_position))
	var intent_body := {
		"wallet": current_wallet,
		"action": "move_mrx",
		"game_pda": current_game_pda,
		"encrypted_position": encrypted_pos,
		"transport": transport,
	}
	var intent_response := await _post_json(base_url + "/api/game/move/intent", intent_body)
	if intent_response.is_empty():
		return
	if not intent_response.has("intent_id") or not intent_response.has("message"):
		emit_signal("error_occurred", "Invalid intent response for move_mr_x")
		return
	var intent_id = intent_response.intent_id
	var message: String = str(intent_response.message)
	var signature := await _get_signature_for_message(message)
	if signature.is_empty():
		emit_signal("error_occurred", "Message signing failed or was cancelled")
		return
	var move_body := {
		"wallet": current_wallet,
		"intent_id": intent_id,
		"signature": signature,
		"game_pda": current_game_pda,
		"encrypted_position": encrypted_pos,
		"transport": transport,
	}
	var move_response := await _post_json(base_url + "/api/game/move/mrx", move_body)
	if move_response.is_empty():
		return
	if move_response.has("success") and move_response.success:
		emit_signal("move_confirmed")
	else:
		var error_msg := "Move Mr. X failed"
		if move_response.has("error"):
			error_msg = str(move_response.error)
		emit_signal("error_occurred", error_msg)

func move_detective(detective_index: int, new_position: int, transport: int):
	print("Detective ", detective_index, " moving to: ", new_position)
	
	if current_game_pda.is_empty():
		emit_signal("error_occurred", "Game PDA not set")
		return
	if not _use_test_endpoints() and current_wallet.is_empty():
		emit_signal("error_occurred", "Wallet not set")
		return
	
	if _use_test_endpoints():
		# API/program expects 1-based detective index (1, 2, 3)
		var move_body := {
			"game_pda": current_game_pda,
			"detective_index": detective_index + 1,
			"new_position": new_position,
			"transport": transport,
		}
		var move_response := await _post_json(base_url + "/api/game/move/detective-test", move_body)
		if move_response.is_empty():
			return
		if move_response.get("success", false):
			emit_signal("move_confirmed")
		else:
			emit_signal("error_occurred", move_response.get("error", "Move detective failed"))
		return
	
	# Web: intent flow
	var intent_body := {
		"wallet": current_wallet,
		"action": "move_detective",
		"game_pda": current_game_pda,
		"detective_index": detective_index + 1,
		"new_position": new_position,
		"transport": transport,
	}
	var intent_response := await _post_json(base_url + "/api/game/move/intent", intent_body)
	if intent_response.is_empty():
		return
	if not intent_response.has("intent_id") or not intent_response.has("message"):
		emit_signal("error_occurred", "Invalid intent response for move_detective")
		return
	var intent_id = intent_response.intent_id
	var message: String = str(intent_response.message)
	var signature := await _get_signature_for_message(message)
	if signature.is_empty():
		emit_signal("error_occurred", "Message signing failed or was cancelled")
		return
	var move_body := {
		"wallet": current_wallet,
		"intent_id": intent_id,
		"signature": signature,
		"game_pda": current_game_pda,
		"detective_index": detective_index + 1,
		"new_position": new_position,
		"transport": transport,
	}
	var move_response := await _post_json(base_url + "/api/game/move/detective", move_body)
	if move_response.is_empty():
		return
	if move_response.has("success") and move_response.success:
		emit_signal("move_confirmed")
	else:
		var error_msg := "Move detective failed"
		if move_response.has("error"):
			error_msg = str(move_response.error)
		emit_signal("error_occurred", error_msg)

func reveal_mr_x(revealed_position: int) -> bool:
	print("Revealing Mr. X at position: ", revealed_position)
	if current_game_pda.is_empty():
		return false
	if _use_test_endpoints():
		var body := { "game_pda": current_game_pda, "revealed_position": revealed_position }
		var resp := await _post_json(base_url + "/api/game/reveal-test", body)
		return resp.get("success", false)
	# TODO: web intent flow for reveal
	return false

func check_capture(detective_index: int, claimed_position: int):
	print("Checking capture at position: ", claimed_position)
	# Placeholder - actual implementation needs wallet signing

# ==================== POLLING ====================

func start_polling():
	polling_timer.start()
	print("Started polling game state")

func stop_polling():
	polling_timer.stop()
	print("Stopped polling game state")

func _poll_game_state():
	if current_game_pda.is_empty():
		return
	fetch_game_state(current_game_pda)

func fetch_game_state(game_pda: String):
	if game_pda.is_empty():
		return
	
	# URL encode the game_pda parameter
	var encoded_pda = game_pda.uri_encode()
	var url = base_url + "/api/game/state?game_pda=" + encoded_pda
	var headers = []
	
	pending_request_type = "fetch_game_state"
	var error = http_request.request(url, headers, HTTPClient.METHOD_GET)
	
	if error != OK:
		emit_signal("error_occurred", "Failed to fetch game state")
		pending_request_type = ""

func _on_request_completed(result, response_code, headers, body):
	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("error_occurred", "HTTP request failed: " + str(result))
		pending_request_type = ""
		return
	
	if response_code != 200:
		var error_msg = "HTTP error: " + str(response_code)
		var body_text = body.get_string_from_utf8()
		if body_text.length() > 0:
			error_msg += " - " + body_text
		emit_signal("error_occurred", error_msg)
		pending_request_type = ""
		return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null:
		emit_signal("error_occurred", "Failed to parse response")
		pending_request_type = ""
		return
	
	# Handle different request types
	match pending_request_type:
		"create_game":
			if json.has("game_id") and json.has("game_pda"):
				current_game_pda = json.game_pda
				GameManager.game_id = str(json.game_id)
				emit_signal("game_created", json.game_id, json.game_pda)
			else:
				emit_signal("error_occurred", "Invalid response from create game")
		
		"join_game":
			if json.has("detective_index"):
				emit_signal("game_joined", json.detective_index)
			else:
				emit_signal("error_occurred", "Invalid response from join game")
		
		"move_mr_x", "move_detective":
			if json.has("success") and json.success:
				emit_signal("move_confirmed")
			else:
				var error_msg = "Move failed"
				if json.has("error"):
					error_msg = json.error
				emit_signal("error_occurred", error_msg)
		
		"fetch_game_state":
			# Parse game state from API response
			var game_state = {
				"game_id": json.get("game_id", 0),
				"detective_positions": json.get("detective_positions", [0, 0, 0]),
				"current_turn": json.get("current_turn", 0),
				"round": json.get("round", 1),
				"status": json.get("status", 0),
				"mr_x_last_transport": json.get("mr_x_last_transport", 0),
				"last_revealed_position": json.get("last_revealed_position", 0),
				"detective_count": json.get("detective_count", 0),
				"max_detectives": json.get("max_detectives", 3)
			}
			emit_signal("game_updated", game_state)
	
	pending_request_type = ""

# ==================== HELPERS ====================

func _derive_game_pda(mr_x_pubkey: String, game_id: int) -> String:
	# In production, use proper PDA derivation
	# For now, return a placeholder
	return "GAME_PDA_" + mr_x_pubkey.substr(0, 8) + "_" + str(game_id)

func _decode_game_state(base64_data: String) -> Dictionary:
	# Decode the base64 account data into a game state dictionary
	# This matches the GameState struct from your Solana program
	
	var decoded = Marshalls.base64_to_raw(base64_data)
	if decoded.size() < 100:  # Minimum expected size
		return {}
	
	# Skip 8-byte discriminator
	var offset = 8
	
	var game_state = {
		"game_id": _read_u64(decoded, offset),
		"mr_x": _read_pubkey(decoded, offset + 8),
		"mr_x_position": _read_bytes(decoded, offset + 40, 32),
		"detectives": [
			_read_pubkey(decoded, offset + 72),
			_read_pubkey(decoded, offset + 104),
			_read_pubkey(decoded, offset + 136)
		],
		"detective_positions": [
			decoded[offset + 168],
			decoded[offset + 169],
			decoded[offset + 170]
		],
		"detective_count": decoded[offset + 171],
		"max_detectives": decoded[offset + 172],
		"current_turn": decoded[offset + 173],
		"round": decoded[offset + 174],
		"rounds_between_reveals": decoded[offset + 175],
		"last_revealed_position": decoded[offset + 176],
		"last_revealed_round": decoded[offset + 177],
		"max_rounds": decoded[offset + 178],
		"status": decoded[offset + 179],
		"mr_x_last_transport": decoded[offset + 180],
		"bump": decoded[offset + 181]
	}
	
	return game_state

func _read_u64(data: PackedByteArray, offset: int) -> int:
	var value = 0
	for i in range(8):
		value += data[offset + i] << (i * 8)
	return value

func _read_pubkey(data: PackedByteArray, offset: int) -> String:
	var bytes = data.slice(offset, offset + 32)
	return Marshalls.raw_to_base64(bytes)

func _read_bytes(data: PackedByteArray, offset: int, length: int) -> PackedByteArray:
	return data.slice(offset, offset + length)

## Encrypts a position using Inco Lightning via the API.
## Returns Array of 32 bytes for use with create_game / move_mr_x.
## Falls back to placeholder if API is unavailable.
func encrypt_position(position: int) -> Array:
	var body := {"value": position}
	var resp := await _post_json(base_url + "/api/encrypt", body)
	if resp.is_empty() or not resp.has("encrypted_position"):
		# Fallback: placeholder for offline / API down
		var fallback := []
		fallback.append(position)
		for i in range(31):
			fallback.append(0)
		return fallback
	return resp.encrypted_position

## Deprecated: use encrypt_position() with await instead.
## Kept for backwards compatibility; calls encrypt_position.
func generate_encrypted_position(position: int) -> Array:
	# Synchronous fallback: return placeholder (callers should use encrypt_position with await)
	var encrypted = []
	encrypted.append(position)
	for i in range(31):
		encrypted.append(0)
	return encrypted

# ==================== INTERNAL HELPERS ====================

func _use_test_endpoints() -> bool:
	# Desktop (no Phantom): use create-test, join-test, mrx-test, detective-test — no signing.
	return not OS.has_feature("web")

func _post_json(url: String, body: Dictionary) -> Dictionary:
	# Utility to POST JSON and get a Dictionary response.
	var http := HTTPRequest.new()
	add_child(http)
	
	var json_body := JSON.stringify(body)
	var headers := ["Content-Type: application/json"]
	var err := http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		http.queue_free()
		emit_signal("error_occurred", "Failed to send HTTP request to " + url)
		return {}
	
	var response = await http.request_completed
	http.queue_free()
	
	var result: int = response[0]
	var response_code: int = response[1]
	var response_body: PackedByteArray = response[3]
	
	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("error_occurred", "HTTP request failed (" + str(result) + ") for " + url)
		return {}
	
	if response_code != 200:
		var body_text := response_body.get_string_from_utf8()
		var msg := "HTTP " + str(response_code) + " from " + url
		if body_text.length() > 0:
			msg += " - " + body_text
		emit_signal("error_occurred", msg)
		return {}
	
	var json = JSON.parse_string(response_body.get_string_from_utf8())
	if json == null:
		emit_signal("error_occurred", "Failed to parse JSON response from " + url)
		return {}
	
	if typeof(json) != TYPE_DICTIONARY:
		emit_signal("error_occurred", "Unexpected JSON type from " + url)
		return {}
	
	return json

func _get_signature_for_message(message: String) -> String:
	# On web: use Phantom via JS. On desktop: use placeholder so test endpoints work.
	if OS.has_feature("web"):
		return await _sign_message_with_js(message)
	return DESKTOP_TEST_SIGNATURE

func _sign_message_with_js(message: String) -> String:
	# Ask the browser (Phantom) to sign a message when running on Web.
	# Expects a global JS function `signMessageForGodot(message)` that
	# stores the signature in `window.godotMessageSignature`.
	if not OS.has_feature("web"):
		# Non-web builds can't sign via JS bridge; caller can decide how to handle this.
		print("Signing via JavaScriptBridge is only available on Web export.")
		return ""
	
	# Safely embed the message into JavaScript using JSON.stringify-style quoting.
	var safe_message := JSON.stringify(message)
	var js_code := "signMessageForGodot(" + safe_message + ")"
	JavaScriptBridge.eval(js_code)
	
	# Wait briefly for the JS promise/async flow to complete.
	await get_tree().create_timer(1.0).timeout
	
	var signature = JavaScriptBridge.eval("window.godotMessageSignature || ''")
	if typeof(signature) != TYPE_STRING:
		return ""
	
	return signature
