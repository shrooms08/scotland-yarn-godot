extends Node

# Audio players
var music_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer

# Preloaded sounds
var button_click_sound: AudioStream
var background_music: AudioStream

func _ready():
	# Create music player
	music_player = AudioStreamPlayer.new()
	music_player.bus = "Master"
	music_player.volume_db = -10  # Adjust music volume (lower = quieter)
	add_child(music_player)
	
	# Create SFX player
	sfx_player = AudioStreamPlayer.new()
	sfx_player.bus = "Master"
	sfx_player.volume_db = 0
	add_child(sfx_player)
	
	# Load sounds
	button_click_sound = load("res://Sounds/button_click.mp3")
	background_music = load("res://Sounds/background_music.wav")

func play_button_click():
	if button_click_sound:
		sfx_player.stream = button_click_sound
		sfx_player.play()

func play_background_music():
	if background_music and not music_player.playing:
		music_player.stream = background_music
		music_player.play()

func stop_background_music():
	music_player.stop()

func set_music_volume(volume_db: float):
	music_player.volume_db = volume_db

func set_sfx_volume(volume_db: float):
	sfx_player.volume_db = volume_db

func toggle_music():
	if music_player.playing:
		music_player.stop()
	else:
		play_background_music()
