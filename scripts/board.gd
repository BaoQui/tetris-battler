extends Node2D
class_name TetrisBoard

## Attach to a Node2D in your main scene, alongside a TileMap that shares
## the same cell_size. Assign player_path to the platformer character.
## Requires Input Map actions: move_left, move_right, rotate_cw, soft_drop,
## hard_drop (hard_drop is now held, not just tapped), plus one ready-up
## action per player (defaults: player1_ready_action / player2_ready_action
## below — point these at whatever button each player's device/side uses).

signal piece_locked(cells)
signal player_squashed
signal topped_out
signal life_lost(remaining_lives: int)      # fires every squash, including the one that hits zero
signal lives_depleted                        # fires once, right when remaining_lives hits 0
signal lives_reset(new_lives: int)           # fires whenever the lives counter is (re)filled
signal match_started                         # fires once both players ready up and play actually begins

# --- ready-up gate (also re-shown after every death) ---
@export var player1_ready_action := "player1_ready"   # Input Map action — point at P1's button
@export var player2_ready_action := "player2_ready"   # Input Map action — point at P2's button

# --- ready-up HUD look/placement — tweak these in the Inspector ---
@export var ready_hud_position := Vector2(0, -80)   # offset from dead-center of the screen
@export var ready_hud_font: Font                     # optional — drop in a custom Font resource to reskin it
@export var ready_hud_title_font_size := 36
@export var ready_hud_status_font_size := 20

@export var grid_width := 8          # narrower than classic 10 = tighter
@export var grid_height := 20        # corridor for the platformer to dodge in
@export var cell_size := 32          # on-screen size of each grid cell (gameplay scale)
@export var tile_map_layer: TileMapLayer
@export var active_piece_layer: TileMapLayer   # child of tile_map_layer — shows the falling piece
@export var next_piece_layer: TileMapLayer     # standalone — place wherever you want the preview shown
@export var player_path: NodePath
@export var block_texture: Texture2D    # the 16x16 sheet used by the Blocks TileSet
@export var block_source_id := 0        # TileSet source id — check the Blocks TileSet if unsure
@export var atlas_tile_size := 16       # the RAW pixel size of one tile in block_texture — must match your asset sheet, NOT cell_size
@export var camera: Camera2D            # drag in your Camera2D node in Inspector

# --- solid falling-piece collision ---
@export var piece_body: AnimatableBody2D   # child of tile_map_layer, Sync to Physics ON

# --- lives ---
@export var starting_lives := 3   # change this in the Inspector to tune life count
@export var respawn_cells_above_board := 2   # how far above the board top the player drops in from on restart

# --- feel / difficulty knobs, tune these by playtesting ---
@export var fall_interval := 0.8     # seconds per auto-drop step
@export var soft_drop_multiplier := 8.0
@export var lock_delay := 0.5        # grace period once a piece touches down
@export var squash_landing_tolerance := 4.0   # pixels of "barely sunk in from standing on top" to ignore when checking for a squash — stops riding a piece down (or standing on it as it locks) from reading as its underside hitting you. Raise this if you still see stray hits.

# --- hold-to-charge slam ---
@export var telegraph_duration := 0.5   # MINIMUM warning time before any drop — even an instant tap waits this long
@export var mega_charge_time := 1.2     # hold hard_drop this long (from initial press) to auto-fire a mega slam
@export var slam_cooldown := 3.0        # cooldown after ANY drop (normal or mega) before hard_drop works again

# --- visual drop speed (the "not an instant teleport" catch-up animation) ---
@export var drop_visual_duration := 0.1   # normal/tap slam
@export var mega_drop_duration := 0.06    # snappier for a held mega slam

# --- rotate pop ---
@export var rotate_punch_amount := 1.06
@export var rotate_punch_duration := 0.08

# --- camera shake, all independently tunable ---
@export var gravity_lock_shake_duration := 0.06   # normal piece landing on its own (not a slam)
@export var gravity_lock_shake_strength := 3.0
@export var slam_shake_duration := 0.15           # tap slam
@export var slam_shake_strength := 8.0
@export var mega_shake_duration := 0.25           # held mega slam
@export var mega_shake_strength := 16.0

# --- bottom-of-board hazard ---
@export var floor_hazard_rows := 1        # how many rows counted as "the bottom" count as a hazard
@export var floor_hazard_debounce := 0.2  # min seconds between bottom-hazard hits while standing in it

# --- damage screen flash (in addition to the sprite flash on the player) ---
# Tune these two directly in the Inspector to taste.
@export var damage_flash_color := Color(0.9, 0.05, 0.05, 0.55)
@export var damage_flash_duration := 0.4

# --- damage screen shake (separate knobs from the piece-lock shakes above,
# on purpose — this one should read as "you got hit", not "a block landed") ---
@export var damage_shake_duration := 0.12
@export var damage_shake_strength := 5.0

# --- sfx, all optional — leave any of these empty in the Inspector to skip it ---
@export var move_sfx: AudioStreamPlayer
@export var rotate_sfx: AudioStreamPlayer
@export var charge_sfx: AudioStreamPlayer     # plays while holding hard_drop; stops the instant it resolves
@export var slam_sfx: AudioStreamPlayer
@export var mega_slam_sfx: AudioStreamPlayer  # tip: use the SAME clip as slam_sfx, just raise this node's Volume dB
@export var lock_sfx: AudioStreamPlayer       # plays on every lock, slam or not
@export var squash_sfx: AudioStreamPlayer
@export var line_clear_sfx: AudioStreamPlayer   # plays when a squash clears the bottom row
@export var death_sfx: AudioStreamPlayer        # plays once, when lives hit zero

var grid: Array = []                 # grid[y][x] = piece name String or ""
var current_piece: String
var next_piece: String = ""
var rotation_state := 0
var piece_pos: Vector2i
var fall_timer := 0.0
var lock_timer := 0.0
var slam_cooldown_timer := 0.0
var bag: Array = []
var player_ref: Node2D

# charge state
var charging := false
var released_early := false
var charge_time := 0.0

# collision shapes for the falling piece — 4 reused, enable/disable per cell
var _piece_shapes: Array[CollisionShape2D] = []

var current_lives := 0
var _board_home_y := 0.0   # tile_map_layer's normal Y, cached before the death-collapse tween
var _squash_debounce := 0.0   # guards against the grid check and the player's physics signal both firing the same instant

# --- hard-drop squash timing ---
# True for the one physics frame a hard-dropped piece sits at its final
# resting position before we decide whether to lock it. Locking used to
# happen in the same tick as the drop, which disabled piece_body's solid
# shapes before the physics engine ever got a chance to push the player
# and fire the reliable is_on_ceiling() squash detection — the window for
# real contact to register was zero frames long. Waiting one physics frame
# gives that contact a chance to happen first, same as a normal
# gravity-driven landing.
var _awaiting_hard_drop_resolution := false

# --- bottom hazard state ---
var _floor_hazard_timer := 0.0

# --- damage screen flash (created lazily so no scene setup is required) ---
var _damage_flash_rect: ColorRect

# --- ready-up gate ---
enum GameState { WAITING_FOR_READY, PLAYING }
var game_state: GameState = GameState.WAITING_FOR_READY
var _player1_ready := false
var _player2_ready := false

# --- HUDs, all lazily built the first time they're needed (same pattern as
# _damage_flash_rect above) so nothing has to be wired up in the scene. ---
var _lives_hud_label: RichTextLabel
var _ready_hud_layer: CanvasLayer
var _ready_p1_label: Label
var _ready_p2_label: Label
var _slam_cd_bar: ProgressBar
var _slam_cd_label: Label


func _grid_origin() -> Vector2:
	# Single source of truth: wherever you drag the Blocks node IS the
	# origin. No separate value to keep in sync by hand.
	if tile_map_layer:
		return tile_map_layer.position
	return Vector2.ZERO


func _ready() -> void:
	grid.resize(grid_height)
	for y in grid_height:
		var row := []
		row.resize(grid_width)
		for x in grid_width:
			row[x] = ""
		grid[y] = row
	if player_path != NodePath():
		player_ref = get_node(player_path)
	current_lives = starting_lives
	player_squashed.connect(_on_player_squashed)
	if player_ref and player_ref.has_signal("squashed"):
		# Primary squash detection: the player's own physics contact,
		# which correctly sees "hit from directly above" even now that
		# PieceBody is solid and grid-cell overlap can't happen anymore.
		player_ref.squashed.connect(_on_player_squashed)
	if piece_body:
		# Lets player.gd recognize this body specifically as "a falling
		# piece" rather than any old solid object, so a bonk against a
		# locked stack from below doesn't get mistaken for a squash.
		piece_body.add_to_group("tetris_piece")
	if piece_body and tile_map_layer and tile_map_layer.tile_set:
		# Pull the real tile size from the TileSet rather than guessing with
		# cell_size — PieceBody is a child of tile_map_layer, so it already
		# inherits that layer's scale. Baking cell_size in on top of that
		# double-applies scale and is what caused the collider to be offset
		# and the wrong size relative to the visible block.
		var tile_size: Vector2 = tile_map_layer.tile_set.tile_size
		for i in 4:
			var shape := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = tile_size
			shape.shape = rect
			shape.disabled = true
			piece_body.add_child(shape)
			_piece_shapes.append(shape)
	elif piece_body:
		push_warning("PieceBody is assigned but tile_map_layer or its TileSet is missing — falling-piece collision will not work.")
	_update_lives_hud()
	_enter_ready_state()


## Freezes the tetris side of the game entirely — no falling piece, no
## piece-control input (see the gate at the top of _unhandled_input), no
## damage of any kind (the early return at the top of _physics_process
## skips the floor hazard check and every timer this file owns) — and
## shows the ready overlay. Called once at startup and again every time a
## player dies, per the "die -> respawn -> both ready up again" loop.
func _enter_ready_state() -> void:
	game_state = GameState.WAITING_FOR_READY
	_player1_ready = false
	_player2_ready = false
	current_piece = ""
	if active_piece_layer:
		active_piece_layer.clear()
	for shape in _piece_shapes:
		shape.disabled = true
	_update_ready_hud()


## Polled every physics frame while WAITING_FOR_READY (rather than through
## _unhandled_input, which is fully blocked in that state) so a ready press
## works no matter which frame it lands on.
func _check_ready_input() -> void:
	if not _player1_ready and Input.is_action_just_pressed(player1_ready_action):
		_player1_ready = true
	if not _player2_ready and Input.is_action_just_pressed(player2_ready_action):
		_player2_ready = true
	_update_ready_hud()
	if _player1_ready and _player2_ready:
		_start_match()


func _start_match() -> void:
	game_state = GameState.PLAYING
	_hide_ready_hud()
	emit_signal("match_started")
	next_piece = _draw_from_bag()
	spawn_piece()


## Runs on the physics tick (not _process) on purpose: piece_body is an
## AnimatableBody2D with Sync to Physics on, which needs its position set
## inside _physics_process to compute a stable push against the player.
## Updating it from _process (variable framerate) was the root cause of the
## "sponged sideways" / unreliable-squash feeling — the physics engine was
## getting the piece's position at inconsistent, non-physics-tick moments.
func _physics_process(delta: float) -> void:
	if game_state == GameState.WAITING_FOR_READY:
		_check_ready_input()
		return

	if slam_cooldown_timer > 0.0:
		slam_cooldown_timer -= delta
	_update_slam_cooldown_hud()
	if _squash_debounce > 0.0:
		_squash_debounce -= delta
	if _floor_hazard_timer > 0.0:
		_floor_hazard_timer -= delta

	# Runs every frame regardless of charging/hard-drop state — standing in
	# the hazard should hurt no matter what the current piece is doing.
	_check_floor_hazard()

	if charging:
		charge_time += delta
		var ratio := clampf(charge_time / mega_charge_time, 0.0, 1.0)
		if active_piece_layer:
			# Flash gets faster and redder the longer you hold.
			var blink_speed := lerpf(10.0, 28.0, ratio)
			active_piece_layer.visible = sin(charge_time * blink_speed) > 0.0
			active_piece_layer.self_modulate = Color(1, lerp(0.3, 0.0, ratio), lerp(0.3, 0.0, ratio))

		var mega_reached := charge_time >= mega_charge_time
		var min_satisfied := charge_time >= telegraph_duration

		if mega_reached:
			_finish_charge(true)
		elif released_early and min_satisfied:
			_finish_charge(false)
		return

	if _awaiting_hard_drop_resolution:
		# Piece is parked at its final spot for this one frame, waiting to
		# see if physics (is_on_ceiling() in player.gd) reacts to it before
		# _execute_hard_drop decides whether to lock it. Don't let the
		# normal grounded/lock-timer path run a second, racing check.
		_update_active_piece_visual()
		return

	var grounded := not _fits(current_piece, rotation_state, piece_pos + Vector2i(0, 1))

	if grounded:
		# Same fix as the falling branch below: check every frame the piece
		# sits here waiting out lock_delay, instead of only once when the
		# timer finally expires. A player who walks under it mid-delay used
		# to go unnoticed until lock_timer ran out (up to lock_delay
		# seconds late, or not at all if they'd already walked back out).
		if _check_squash(current_piece, rotation_state, piece_pos):
			emit_signal("player_squashed")
		else:
			lock_timer -= delta
			if lock_timer <= 0.0:
				_settle_or_squash()
	else:
		lock_timer = lock_delay
		fall_timer += delta
		var interval := fall_interval
		if Input.is_action_pressed("soft_drop"):
			interval /= soft_drop_multiplier
		if fall_timer >= interval:
			fall_timer = 0.0
			piece_pos += Vector2i(0, 1)
		# Grid-level backup check for a normal (non-hard-drop) fall. Used to
		# live inside the `if fall_timer >= interval:` block above, so it
		# only ever looked at the world in the single frame the piece
		# stepped down a row — a snapshot taken once per fall_interval
		# (0.8s for a normal fall, ~0.1s for a soft drop). Between
		# snapshots nothing was watching, so a player could walk under a
		# piece that was just sitting there mid-interval and never get
		# caught — and since the miss window scales with the interval,
		# normal falls (0.8s gaps) were flakier than soft drops (0.1s
		# gaps), exactly backwards from what you'd expect. Checking every
		# physics frame against wherever the piece currently sits — moved
		# this frame or not — closes that gap. piece_body's own physics
		# contact (is_on_ceiling() in player.gd) is still the primary way
		# this gets detected; this is the backup for the case where a
		# step is a full cell (32px) in one tick and the player's hitbox
		# is thin enough that the two never actually overlap mid-motion.
		if _check_squash(current_piece, rotation_state, piece_pos):
			emit_signal("player_squashed")

	_update_active_piece_visual()


func _unhandled_input(event: InputEvent) -> void:
	if game_state != GameState.PLAYING:
		return

	if charging:
		# Still allowed to move left/right while charged.
		if event.is_action_pressed("move_left"):
			_try_move(Vector2i(-1, 0))
		elif event.is_action_pressed("move_right"):
			_try_move(Vector2i(1, 0))
		elif event.is_action_released("hard_drop"):
			released_early = true
		return

	if event.is_action_pressed("move_left"):
		_try_move(Vector2i(-1, 0))
	elif event.is_action_pressed("move_right"):
		_try_move(Vector2i(1, 0))
	elif event.is_action_pressed("rotate_cw"):
		_try_rotate(1)
	elif event.is_action_pressed("hard_drop") and slam_cooldown_timer <= 0.0:
		charging = true
		released_early = false
		charge_time = 0.0
		if charge_sfx:
			charge_sfx.play()


func _finish_charge(is_mega: bool) -> void:
	charging = false
	released_early = false
	if charge_sfx:
		charge_sfx.stop()
	_execute_hard_drop(is_mega)


func _execute_hard_drop(is_mega: bool = false) -> void:
	if active_piece_layer:
		active_piece_layer.visible = true
		active_piece_layer.self_modulate = Color(1, 1, 1)

	var start_pos := piece_pos
	var drop_pos := piece_pos
	var hit_player_mid_drop := false
	# Sweep down one cell at a time instead of jumping straight to the grid
	# rest position. _fits() only knows about the floor/locked stack — it
	# has no idea where the player is — so the old version could drop
	# clean through the player to land at the bottom, and piece_body
	# teleporting that whole distance in one tick was too large a jump for
	# the physics engine to register as a continuous push. Checking a
	# squash at each intermediate row means the piece now stops for
	# damage purposes the instant it reaches the player, same as a normal
	# gravity fall step already does.
	while _fits(current_piece, rotation_state, drop_pos + Vector2i(0, 1)):
		var next_pos := drop_pos + Vector2i(0, 1)
		if _check_squash(current_piece, rotation_state, next_pos):
			drop_pos = next_pos
			hit_player_mid_drop = true
			break
		drop_pos = next_pos
	piece_pos = drop_pos
	_update_active_piece_visual()   # syncs piece_body to drop_pos with shapes enabled

	# Visual-only catch-up: snap the render node to where the piece started,
	# then tween it down. The logic already resolved instantly above (so
	# collision/squash timing is untouched) — this just makes the eye see a
	# fast fall instead of a teleport. Mega gets a snappier tween. Runs
	# whether or not the drop hit the player, so a slam that connects still
	# reads as "fell that whole distance" rather than snapping silently.
	# NOTE: piece_body snaps to its resting spot immediately (it's synced
	# in _update_active_piece_visual above), so the solid collider is
	# sitting at the bottom slightly before the visual tween catches up.
	if active_piece_layer:
		var pixel_drop := (drop_pos.y - start_pos.y) * cell_size
		active_piece_layer.position.y = -pixel_drop
		var drop_duration := mega_drop_duration if is_mega else drop_visual_duration
		create_tween().tween_property(active_piece_layer, "position:y", 0.0, drop_duration)

	if hit_player_mid_drop:
		emit_signal("player_squashed")
		return

	# Give physics a window to react to piece_body sitting at its final,
	# solid position — this is what lets is_on_ceiling() in player.gd catch
	# a squash on a hard drop the same way it already does for a normal
	# gravity landing. Used to be a single await get_tree().physics_frame,
	# but the VISUAL tween above keeps showing the piece "still falling"
	# for drop_visual_duration/mega_drop_duration (several physics frames
	# at 60fps) after it's already logically resolved and eligible to lock.
	# A player jumping up into it mid-tween — which still looks like a live
	# slam — had only that one frame to actually register contact before
	# the piece locked into static terrain out from under them, which is
	# exactly the "just shoves them out of the way" behavior. Widening the
	# window to match the visual, and checking every frame of it instead of
	# only at the end, means anything that still LOOKS like it's landing
	# also still COUNTS as landing.
	_awaiting_hard_drop_resolution = true
	var resolution_window := mega_drop_duration if is_mega else drop_visual_duration
	var elapsed := 0.0
	while elapsed < resolution_window:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()

		if not _awaiting_hard_drop_resolution:
			# _on_player_squashed already fired and handled everything
			# during a frame we waited on — nothing left to lock.
			return

		if _check_squash(current_piece, rotation_state, piece_pos):
			_awaiting_hard_drop_resolution = false
			emit_signal("player_squashed")
			return
	_awaiting_hard_drop_resolution = false

	_lock_piece()
	if is_mega:
		_shake_camera(mega_shake_duration, mega_shake_strength)
		if mega_slam_sfx:
			mega_slam_sfx.play()
	else:
		_shake_camera(slam_shake_duration, slam_shake_strength)
		if slam_sfx:
			slam_sfx.play()
	slam_cooldown_timer = slam_cooldown


func _settle_or_squash() -> void:
	if _check_squash(current_piece, rotation_state, piece_pos):
		emit_signal("player_squashed")
	else:
		_lock_piece()
		_shake_camera(gravity_lock_shake_duration, gravity_lock_shake_strength)


## Continuous floor hazard: touching the bottom rows of the board damages
## the player regardless of cause — pushed down by a piece, dashed in,
## fell through a gap, whatever. Runs every physics frame; the debounce
## keeps it from draining a life every single tick while they're standing
## in it, but it WILL keep hurting them repeatedly the longer they stay,
## same as any other instant-damage floor.
func _check_floor_hazard() -> void:
	if player_ref == null or _floor_hazard_timer > 0.0:
		return
	var player_cells := _get_player_occupied_cells()
	for pc in player_cells:
		if pc.y >= grid_height - floor_hazard_rows:
			_floor_hazard_timer = floor_hazard_debounce
			emit_signal("player_squashed")
			return


## Handles every squash, whether it came from a normal settle, a hard drop,
## the fall-step tunneling backup, or the floor hazard. Clears the piece
## that caused it (it never gets added to the grid — it's gone, not
## locked) so the per-frame grounded/lock_timer check in _process can't
## immediately re-trigger a squash on the very next frame while the player
## is still standing in the same spot.
func _on_player_squashed() -> void:
	_awaiting_hard_drop_resolution = false   # let a pending hard drop know it's already been handled

	# player.gd's take_hit() is now the single gate every damage source
	# goes through — the piece-contact check inside player.gd's own
	# _physics_process, AND every emit_signal("player_squashed") in this
	# file (grid-backup fall check above, hard-drop resolution, floor
	# hazard below) — since all of them end up here. It returns false
	# while the post-hit invincibility window (knockback + blink) from a
	# previous hit is still running, which is what stops those sources
	# from chain-hitting the player frame after frame. _squash_debounce is
	# now only a fallback for the case where there's no player_ref to ask.
	if player_ref and player_ref.has_method("take_hit"):
		if not player_ref.take_hit():
			return
	else:
		if _squash_debounce > 0.0:
			return
		_squash_debounce = 0.2
		if player_ref and player_ref.has_method("flash_hurt"):
			player_ref.flash_hurt()

	if squash_sfx:
		squash_sfx.play()

	# Full-screen flash so damage reads as damage regardless of what's on
	# screen. The player's own hit feedback (blink/knockback) is now
	# handled entirely inside take_hit() above.
	_flash_screen_damage()
	_shake_camera(damage_shake_duration, damage_shake_strength)

	if active_piece_layer:
		active_piece_layer.clear()
	for shape in _piece_shapes:
		shape.disabled = true

	current_lives -= 1
	emit_signal("life_lost", current_lives)
	_update_lives_hud()

	if current_lives <= 0:
		emit_signal("lives_depleted")
		if death_sfx:
			death_sfx.play()
		_begin_death_reset()
	else:
		_clear_row(grid_height - 1)
		if line_clear_sfx:
			line_clear_sfx.play()
		spawn_piece()


## Lazily builds a full-screen CanvasLayer + ColorRect so the damage flash
## works without requiring any extra nodes in the scene, then flashes it.
## CanvasLayer draws in screen space, so this covers the viewport
## regardless of where the camera or board happen to be positioned.
func _flash_screen_damage() -> void:
	if not _damage_flash_rect:
		var layer := CanvasLayer.new()
		layer.layer = 100
		var rect := ColorRect.new()
		rect.color = Color(damage_flash_color.r, damage_flash_color.g, damage_flash_color.b, 0.0)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.add_child(rect)
		add_child(layer)
		_damage_flash_rect = rect

	_damage_flash_rect.color.a = damage_flash_color.a
	create_tween().tween_property(_damage_flash_rect, "color:a", 0.0, damage_flash_duration)


## Lazily builds a small top-left "lives remaining" readout — filled hearts
## for lives you still have, hollow gray ones for lives already spent — and
## refreshes it. No texture assets required, so nothing to wire up in the
## scene; swap the glyphs below for real icons later if you want.
func _ensure_lives_hud() -> void:
	if _lives_hud_label:
		return
	var layer := CanvasLayer.new()
	layer.layer = 90
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.position = Vector2(16, 16)
	label.add_theme_font_size_override("normal_font_size", 28)
	layer.add_child(label)
	add_child(layer)
	_lives_hud_label = label


func _update_lives_hud() -> void:
	_ensure_lives_hud()
	var bbcode := ""
	for i in starting_lives:
		if i < current_lives:
			bbcode += "[color=#e63946]♥[/color] "
		else:
			bbcode += "[color=#555555]♡[/color] "
	_lives_hud_label.text = bbcode.strip_edges()


## Lazily builds the centered "GET READY" overlay with a per-player ready
## status line, shown by _enter_ready_state() and hidden once _start_match()
## fires. Built the same way as the damage flash above: a CanvasLayer so it
## draws in screen space regardless of camera position, no scene wiring.
func _ensure_ready_hud() -> void:
	if _ready_hud_layer:
		return
	var layer := CanvasLayer.new()
	layer.layer = 95
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position += ready_hud_position   # nudge away from dead-center — tune in the Inspector
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var title := Label.new()
	title.text = "GET READY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", ready_hud_title_font_size)
	if ready_hud_font:
		title.add_theme_font_override("font", ready_hud_font)
	box.add_child(title)
	_ready_p1_label = Label.new()
	_ready_p1_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ready_p1_label.add_theme_font_size_override("font_size", ready_hud_status_font_size)
	if ready_hud_font:
		_ready_p1_label.add_theme_font_override("font", ready_hud_font)
	box.add_child(_ready_p1_label)
	_ready_p2_label = Label.new()
	_ready_p2_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ready_p2_label.add_theme_font_size_override("font_size", ready_hud_status_font_size)
	if ready_hud_font:
		_ready_p2_label.add_theme_font_override("font", ready_hud_font)
	box.add_child(_ready_p2_label)
	root.add_child(box)
	layer.add_child(root)
	add_child(layer)
	_ready_hud_layer = layer


func _update_ready_hud() -> void:
	_ensure_ready_hud()
	_ready_hud_layer.visible = true
	_ready_p1_label.text = "Player 1: READY" if _player1_ready else "Player 1: press to ready up"
	_ready_p1_label.add_theme_color_override("font_color", Color.LIME_GREEN if _player1_ready else Color.WHITE)
	_ready_p2_label.text = "Player 2: READY" if _player2_ready else "Player 2: press to ready up"
	_ready_p2_label.add_theme_color_override("font_color", Color.LIME_GREEN if _player2_ready else Color.WHITE)


func _hide_ready_hud() -> void:
	if _ready_hud_layer:
		_ready_hud_layer.visible = false


## Lazily builds a small top-right bar + label showing time left until
## hard_drop is usable again — green and "SLAM READY" when it's off
## cooldown, filling red bar + countdown while it's not.
func _ensure_slam_cooldown_hud() -> void:
	if _slam_cd_bar:
		return
	var layer := CanvasLayer.new()
	layer.layer = 90
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 100
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(140, 18)
	bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	bar.position = Vector2(-156, 16)
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	label.position = Vector2(-156, 16)
	label.custom_minimum_size = Vector2(140, 18)
	label.add_theme_font_size_override("font_size", 12)
	layer.add_child(bar)
	layer.add_child(label)
	add_child(layer)
	_slam_cd_bar = bar
	_slam_cd_label = label


func _update_slam_cooldown_hud() -> void:
	_ensure_slam_cooldown_hud()
	if slam_cooldown_timer > 0.0:
		_slam_cd_bar.value = (1.0 - slam_cooldown_timer / slam_cooldown) * 100.0
		_slam_cd_bar.modulate = Color(0.9, 0.3, 0.2)
		_slam_cd_label.text = "SLAM %.1fs" % slam_cooldown_timer
	else:
		_slam_cd_bar.value = 100.0
		_slam_cd_bar.modulate = Color(0.3, 0.9, 0.3)
		_slam_cd_label.text = "SLAM READY"


## Clears a single row and drops everything above it down by one, same as a
## normal Tetris line clear — used here as the "mercy" effect on a squash
## rather than requiring the row to be full.
func _clear_row(row: int) -> void:
	for y in range(row, 0, -1):
		grid[y] = grid[y - 1].duplicate()
	var top_row := []
	top_row.resize(grid_width)
	for x in grid_width:
		top_row[x] = ""
	grid[0] = top_row
	_redraw_grid()


## Full redraw of tile_map_layer from the grid array. Simpler and less
## error-prone than shifting individual set_cell/erase_cell calls up one by
## one, and cheap enough at this board size to just do every clear.
func _redraw_grid() -> void:
	if not tile_map_layer:
		return
	tile_map_layer.clear()
	for y in grid_height:
		for x in grid_width:
			var piece_name: String = grid[y][x]
			if piece_name != "":
				tile_map_layer.set_cell(Vector2i(x, y), block_source_id, TetrominoData.TILE_ATLAS_COORDS[piece_name])


## Placeholder collapse visual for hitting zero lives — tweens the whole
## stack down and out of frame so there's SOME feedback immediately. Swap
## this out (or call finish_death_reset() directly from) your team's real
## "blocks fall with the player's body, player returns as an angel"
## animation once that's built — same pattern as the win cutscene: this
## script fires the signal / does the mechanical reset, the actual
## animation work lives outside it.
func _begin_death_reset() -> void:
	if tile_map_layer:
		_board_home_y = tile_map_layer.position.y
		var drop_distance := float(grid_height * cell_size)
		var t := create_tween()
		t.tween_property(tile_map_layer, "position:y", _board_home_y + drop_distance, 0.6)
		t.tween_callback(finish_death_reset)
	else:
		finish_death_reset()


## Call this once the death/respawn animation has finished playing (or
## immediately, if you haven't hooked up that animation yet). Resets the
## board and refills lives, then drops back into the ready-wait state —
## both players have to ready up again before the next piece actually
## starts falling, per the "die -> respawn -> ready up again" loop.
func finish_death_reset() -> void:
	if tile_map_layer:
		tile_map_layer.position.y = _board_home_y
	_respawn_player()
	reset_board(true, false)
	_enter_ready_state()


## Places the player horizontally centered on screen (using the camera if
## one's assigned, otherwise centered over the grid) and just above the
## top of the board, then clears their velocity so leftover speed from
## before death doesn't carry into the fall-in. Gravity in player.gd does
## the actual "falling down" — this just sets up where that fall starts.
func _respawn_player() -> void:
	if not player_ref:
		return
	var origin := _grid_origin()
	var spawn_x := origin.x + (grid_width * cell_size) / 2.0
	if camera:
		spawn_x = camera.get_screen_center_position().x
	var spawn_y := origin.y - float(respawn_cells_above_board * cell_size)
	player_ref.global_position = Vector2(spawn_x, spawn_y)
	if "velocity" in player_ref:
		player_ref.velocity = Vector2.ZERO


func _try_move(dir: Vector2i) -> void:
	if _fits(current_piece, rotation_state, piece_pos + dir):
		piece_pos += dir
		_update_active_piece_visual()
		if move_sfx:
			move_sfx.play()


func _try_rotate(dir: int) -> void:
	var new_state := (rotation_state + dir + 4) % 4
	if _fits(current_piece, new_state, piece_pos) and not _overlaps_player(current_piece, new_state, piece_pos):
		rotation_state = new_state
		_update_active_piece_visual()
		_punch_scale(active_piece_layer, rotate_punch_amount, rotate_punch_duration)
		if rotate_sfx:
			rotate_sfx.play()
	# No wall-kick table — a rotation that doesn't fit (wall/stack OR the
	# player standing in the swept space) is just blocked.


## Used only to gate rotation. A rotate swaps piece_body's collision shapes
## straight to their new cells in one frame (_sync_piece_collision teleports
## them, it doesn't sweep) — if that new spot happens to land inside the
## player, the solid shape pops into existence already overlapping them,
## which the physics engine (and player.gd's is_on_ceiling() check) reads
## as a sudden hit from a random direction, not a real "landed on your
## head" contact. Treating the player as one more thing rotation can be
## blocked by avoids that teleport-into-player case entirely, same spirit
## as the existing wall/stack fit check.
func _overlaps_player(piece: String, rot: int, pos: Vector2i) -> bool:
	if player_ref == null:
		return false
	var player_cells := _get_player_occupied_cells()
	if player_cells.is_empty():
		return false
	for cell in _get_world_cells(piece, rot, pos):
		for pc in player_cells:
			if cell == pc:
				return true
	return false


func _fits(piece: String, rot: int, pos: Vector2i) -> bool:
	for offset in TetrominoData.SHAPES[piece][rot]:
		var cell: Vector2i = pos + offset
		if cell.x < 0 or cell.x >= grid_width or cell.y >= grid_height:
			return false
		if cell.y >= 0 and grid[cell.y][cell.x] != "":
			return false
	return true


func _get_world_cells(piece: String, rot: int, pos: Vector2i) -> Array:
	var cells := []
	for offset in TetrominoData.SHAPES[piece][rot]:
		cells.append(pos + offset)
	return cells


## Only kills if a piece cell lands on the player's TOP row (their head) —
## overlap with lower rows (feet/side, from clipping into an adjacent
## column) no longer counts. Once locked, that space is solid terrain via
## the TileMapLayer's own collision, so "safe from the side" falls out
## naturally without needing the falling piece to be physically solid.
##
## NOTE: this is also why a lock can leave the player embedded in the new
## terrain (feet/torso overlap doesn't count as a squash, but the cell
## still turns solid) — that's what player.gd's _resolve_stuck_overlap()
## auto-unstuck is there to clean up every frame, rather than changing
## this squash rule itself.
func _check_squash(piece: String, rot: int, pos: Vector2i) -> bool:
	if player_ref == null:
		return false
	var player_cells := _get_player_occupied_cells(squash_landing_tolerance)
	if player_cells.is_empty():
		return false

	var top_y: int = player_cells[0].y
	for pc in player_cells:
		if pc.y < top_y:
			top_y = pc.y

	for cell in _get_world_cells(piece, rot, pos):
		if cell.y != top_y:
			continue
		for pc in player_cells:
			if cell == pc:
				return true
	return false


func _get_player_occupied_cells(foot_margin: float = 0.0) -> Array:
	# Assumes the player has a CollisionShape2D with a RectangleShape2D.
	# Adjust get_rect() if your friend uses a CapsuleShape2D instead.
	var shape_node := player_ref.get_node("CollisionShape2D") as CollisionShape2D
	var extents: Vector2 = shape_node.shape.get_rect().size / 2.0
	# Use the SHAPE's global position, not the body's. player.gd's
	# change_collision() offsets the shape away from the body origin
	# (standing/crouching/jumping each use a different local position) —
	# using the body origin here ignored that offset entirely, so the
	# "row" this thought the player's head was on drifted by about a cell
	# depending on animation state. That's what caused damage to fire
	# early, late, or not at all depending on what the player was doing.
	var shape_center: Vector2 = shape_node.global_position
	var origin := _grid_origin()
	var top_left: Vector2 = shape_center - global_position - origin - extents
	var bottom_right: Vector2 = shape_center - global_position - origin + extents
	# foot_margin pulls the bottom edge up a few pixels before we floor()
	# it into a row. Without this, standing on top of a piece (or riding
	# one down as it falls) sinks the player a pixel or two into its top
	# row every frame just from gravity ticking before the physics push-out
	# resolves — and floor() turns even a 1px sink into "fully occupies
	# that row", which _check_squash then reads as the piece's underside
	# hitting the player. A few pixels of slack lets "resting on the
	# surface" stay in the row above, while a real squash (the piece
	# actually landing where the player's head is) is still a full-cell
	# overlap and clears the margin easily.
	bottom_right.y -= foot_margin

	var min_x := int(floor(top_left.x / cell_size))
	var max_x := int(floor((bottom_right.x - 1) / cell_size))
	var min_y := int(floor(top_left.y / cell_size))
	var max_y := int(floor((bottom_right.y - 1) / cell_size))

	var cells := []
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			cells.append(Vector2i(x, y))
	return cells


func _lock_piece() -> void:
	var cells := _get_world_cells(current_piece, rotation_state, piece_pos)
	for cell in cells:
		if cell.y < 0:
			emit_signal("topped_out")
			return
		grid[cell.y][cell.x] = current_piece
		if tile_map_layer:
			tile_map_layer.set_cell(cell, block_source_id, TetrominoData.TILE_ATLAS_COORDS[current_piece])
	if active_piece_layer:
		active_piece_layer.clear()
	for shape in _piece_shapes:
		shape.disabled = true
	if lock_sfx:
		lock_sfx.play()
	emit_signal("piece_locked", cells)
	spawn_piece()


func reset_board(reset_lives: bool = true, auto_spawn: bool = true) -> void:
	for y in grid_height:
		for x in grid_width:
			grid[y][x] = ""
	if tile_map_layer:
		tile_map_layer.clear()
	bag.clear()
	slam_cooldown_timer = 0.0
	charging = false
	released_early = false
	charge_time = 0.0
	for shape in _piece_shapes:
		shape.disabled = true
	if reset_lives:
		current_lives = starting_lives
		emit_signal("lives_reset", current_lives)
		_update_lives_hud()
	if auto_spawn:
		next_piece = _draw_from_bag()
		spawn_piece()


func _draw_from_bag() -> String:
	if bag.is_empty():
		bag = TetrominoData.get_piece_names()
		bag.shuffle()
	return bag.pop_back()


func spawn_piece() -> void:
	current_piece = next_piece
	next_piece = _draw_from_bag()
	rotation_state = 0
	piece_pos = Vector2i(grid_width / 2 - 2, 0)
	lock_timer = lock_delay
	fall_timer = 0.0
	if not _fits(current_piece, rotation_state, piece_pos):
		emit_signal("topped_out")
	_update_active_piece_visual()
	_update_next_piece_preview()


## Draws the falling piece through a real TileMapLayer (a child of
## tile_map_layer) instead of hand-rolled _draw() math. Being a child means
## it automatically shares tile_map_layer's exact position/scale.
func _update_active_piece_visual() -> void:
	if not active_piece_layer:
		return
	active_piece_layer.clear()
	if current_piece == "":
		return
	var atlas: Vector2i = TetrominoData.TILE_ATLAS_COORDS[current_piece]
	for cell in _get_world_cells(current_piece, rotation_state, piece_pos):
		if cell.y >= 0:
			active_piece_layer.set_cell(cell, block_source_id, atlas)
	_sync_piece_collision()


## Moves the real physics collider (piece_body) to match the falling piece's
## current grid position/rotation every time the visual updates, so the
## player can stand on top of / bump into a still-falling piece. Cells above
## the visible board (y < 0, during spawn) are disabled so nothing collides
## before the piece is actually on-screen.
func _sync_piece_collision() -> void:
	if not piece_body or not tile_map_layer:
		return
	if current_piece == "":
		for shape in _piece_shapes:
			shape.disabled = true
		return
	# map_to_local() asks the TileMapLayer itself where a cell lives, in its
	# own local space — this automatically matches whatever tile_size and
	# scale it's actually using, instead of us re-deriving pixel offsets by
	# hand with cell_size (which drifts out of sync the moment the layer's
	# scale isn't exactly 1:1 with cell_size).
	var origin_local: Vector2 = tile_map_layer.map_to_local(piece_pos)
	piece_body.position = origin_local
	var offsets: Array = TetrominoData.SHAPES[current_piece][rotation_state]
	for i in _piece_shapes.size():
		if i < offsets.size():
			var off: Vector2i = offsets[i]
			var cell: Vector2i = piece_pos + off
			_piece_shapes[i].disabled = cell.y < 0
			_piece_shapes[i].position = tile_map_layer.map_to_local(cell) - origin_local
		else:
			_piece_shapes[i].disabled = true


## Draws the NEXT piece's rotation-0 shape starting at (0,0) in whatever
## local space next_piece_layer sits in — so wherever you place that node
## in the editor is where the preview shows up. Match its Scale to
## Blocks'/ActivePiece's Scale so the tiles render at the same size.
func _update_next_piece_preview() -> void:
	if not next_piece_layer:
		return
	next_piece_layer.clear()
	if next_piece == "":
		return
	var atlas: Vector2i = TetrominoData.TILE_ATLAS_COORDS[next_piece]
	for offset in TetrominoData.SHAPES[next_piece][0]:
		next_piece_layer.set_cell(offset, block_source_id, atlas)


func _shake_camera(duration: float, strength: float) -> void:
	if not camera:
		return
	var t := create_tween()
	var steps := maxi(1, int(duration / 0.02))
	for i in steps:
		var offset := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		t.tween_property(camera, "offset", offset, 0.02)
	t.tween_property(camera, "offset", Vector2.ZERO, 0.02)


func _punch_scale(node: Node2D, amount := 1.15, duration := 0.1) -> void:
	if not node:
		return
	node.scale = Vector2.ONE * amount
	create_tween().tween_property(node, "scale", Vector2.ONE, duration)
