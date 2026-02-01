extends Control

@onready var connect_button = $VBoxContainer/ConnectWalletButton

var wallet_connected := false

func _ready():
	AudioManager.play_background_music()
	connect_button.pressed.connect(_on_connect_wallet_pressed)

func _on_connect_wallet_pressed():
	AudioManager.play_button_click()
	if wallet_connected:
		get_tree().change_scene_to_file("res://Scene/lobby.tscn")
	else:
		_connect_wallet()

func _connect_wallet():
	print("Connecting wallet...")
	
	# Call JavaScript to connect Phantom
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.solanaWallet.connect().then(pk => { if(pk) window.godotWalletPubkey = pk; })")
		
		# Wait a moment for connection
		await get_tree().create_timer(1.0).timeout
		
		var pubkey = JavaScriptBridge.eval("window.godotWalletPubkey || ''")
		if pubkey != "":
			GlobalSolanaClient.set_wallet(pubkey)
			wallet_connected = true
			connect_button.text = "Enter Game"
			print("Wallet connected: ", pubkey)
		else:
			print("Wallet connection failed")
	else:
		# Desktop fallback - use test wallet
		var test_wallet = "7cBvpuynqNPb66hLAitXXRPsaK8UKNa45zsoCa7rqKou"
		GlobalSolanaClient.set_wallet(test_wallet)
		wallet_connected = true
		connect_button.text = "Enter Game"
		print("Desktop mode - using test wallet")
