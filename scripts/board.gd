extends Node2D
class_name TetrisBoard


signal piece_locked(cells)
signal player_squashed
signal topped_out
signal life_lost(remaining_lives: int)      # fires every squash, including the one that hits zero
signal lives_depleted                        # fires once, right when remaining_lives hits 0
signal lives_reset(new_lives: int)           # fires whenever the lives counter is (re)filled
signal match_started                         # fires once both players ready up and play actually begins

# --- ready-up gate (shown after every round) ---
@export var player1_ready_action := "player1_ready"   # Input Map action — point at P1's button
@export var player2_ready_action := "player2_ready"   # Input Map action — point at P2's button

# --- ready-up HUD look/placement — tweak these in the Inspector ---
@export var ready_hud_position := Vector2(24, -90)   # left edge inset and offset from vertical center
@export var ready_hud_font: Font                     # optional — drop in a custom Font resource to reskin it
@export var ready_hud_title_font_size := 30
@export var ready_hud_status_font_size := 17

@export var grid_width := 8          # narrower than classic 10 = tighter
@export var grid_height := 20        # corridor for the platformer to dodge in
@export var cell_size := 32  # Legacy scene setting; retained for compatibility.
@export var tile_map_layer: TileMapLayer
@export var active_piece_layer: TileMapLayer   # child of tile_map_layer — shows the falling piece
@export var next_piece_layer: TileMapLayer     # standalone — place wherever you want the preview shown
@export var player_path: NodePath
@export var block_texture: Texture2D    # the 16x16 sheet used by the Blocks TileSet
@export var block_source_id := 0        # TileSet source id — check the Blocks TileSet if unsure
@export var atlas_tile_size := 16  # Legacy scene setting; retained for compatibility.
@export var camera: Camera2D            # drag in your Camera2D node in Inspector

# --- solid falling-piece collision ---
@export var piece_body: AnimatableBody2D   # child of tile_map_layer, Sync to Physics ON

# --- lives ---
@export var starting_lives := 3   # change this in the Inspector to tune life count
@export var respawn_cells_above_board := 2  # Legacy scene setting; retained for compatibility.

# --- feel / difficulty knobs, tune these by playtesting ---
@export var fall_interval := 0.8     # seconds per auto-drop step
@export var soft_drop_multiplier := 8.0
@export var lock_delay := 0.5        # grace period once a piece touches down
@export var squash_landing_tolerance := 4.0  # Legacy scene setting; retained for compatibility.

# --- hold-to-charge slam ---
@export var telegraph_duration := 0.5   # MINIMUM warning time before any drop — even an instant tap waits this long
@export var mega_charge_time := 1.2     # hold hard_drop this long (from initial press) to auto-fire a mega slam
@export var slam_cooldown := 3.0        # cooldown after ANY drop (normal or mega) before hard_drop works again

# --- visual drop speed (the "not an instant teleport" catch-up animation) ---
@export var drop_visual_duration := 0.1   # normal/tap slam
@export var mega_drop_duration := 0.06    # snappier for a held mega slam

# --- rotate pop ---
@export var rotate_punch_amount := 1.06  # Legacy scene setting; retained for compatibility.
@export var rotate_punch_duration := 0.08  # Legacy scene setting; retained for compatibility.

# --- camera shake, all independently tunable ---
@export var gravity_lock_shake_duration := 0.06   # normal piece landing on its own (not a slam)
@export var gravity_lock_shake_strength := 3.0
@export var slam_shake_duration := 0.15           # tap slam
@export var slam_shake_strength := 8.0
@export var mega_shake_duration := 0.25           # held mega slam
@export var mega_shake_strength := 16.0

# --- optional floor hazard (disabled unless enable_floor_hazard is on) ---
@export var floor_hazard_rows := 1        # how many rows counted as "the bottom" count as a hazard
@export var floor_hazard_debounce := 0.2  # Legacy scene setting; retained for compatibility.

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

# Round flow. The board owns damage, wins, and resets.
signal round_finished(player_won: bool)
@export var celebration_duration: float = 1.5
@export var collapse_duration: float = 0.7
@export var normal_step_duration: float = 0.08
# Off by default: the requested hazard is a block's underside, not the floor.
@export var enable_floor_hazard: bool = false
# Optional: use this if the scene's win Area2D is not connected to the player.
@export var win_area: Area2D
@export_range(4, 20) var goal_clear_rows: int = 4  # Keep the spawn/goal band open.

enum GameState { WAITING_FOR_READY, PLAYING, CELEBRATING, COLLAPSING }
var game_state: GameState = GameState.WAITING_FOR_READY
var grid: Array = []
var current_piece: String = ""
var next_piece: String = ""
var rotation_state := 0
var piece_pos := Vector2i.ZERO
var fall_timer := 0.0
var lock_timer := 0.0
var slam_cooldown_timer := 0.0
var bag: Array = []
var player_ref: Node2D
var current_lives := 0
var charging := false
var released_early := false
var charge_time := 0.0
var _piece_shapes: Array[CollisionShape2D] = []
var _player1_ready := false
var _player2_ready := false
var _pending_contact := false
var _pending_win := false
var _pending_move := 0
var _pending_rotate := false
var _pending_charge := false
var _motion_active := false
var _motion_from := Vector2.ZERO
var _motion_offset := Vector2.ZERO
var _motion_elapsed := 0.0
var _motion_duration := 0.1
var _slamming := false
var _mega_slam := false
var _spawn_position := Vector2.ZERO
var _shake_tween: Tween
var _flash_tween: Tween
var _punch_tween: Tween
var _round_tween: Tween
var _round_serial := 0
var _debris: Node2D
var _damage_flash_rect: ColorRect
var _lives_hud_label: RichTextLabel
var _ready_hud_layer: CanvasLayer
var _ready_p1_label: Label
var _ready_p2_label: Label
var _slam_cd_bar: ProgressBar
var _slam_cd_label: Label


func _ready() -> void:
	if not tile_map_layer or not tile_map_layer.tile_set or not active_piece_layer:
		push_error("Assign Blocks, ActivePiece, and the Blocks TileSet on the board.")
		set_physics_process(false)
		return
	player_ref = get_node_or_null(player_path) as Node2D
	if not player_ref:
		push_error("Assign the board's player_path to the player.")
		set_physics_process(false)
		return
	_spawn_position = player_ref.global_position
	# The scene's actual start position is reused on every round.
	if player_ref.has_signal("squashed"):
		player_ref.connect("squashed", _queue_player_contact)
	if player_ref.has_signal("win_requested"):
		player_ref.connect("win_requested", _request_win)
	player_squashed.connect(_queue_player_contact)
	_find_connected_win_area()
	if win_area and not win_area.body_entered.is_connected(_on_win_body_entered):
		win_area.body_entered.connect(_on_win_body_entered)
	if not piece_body:
		piece_body = AnimatableBody2D.new()
		tile_map_layer.add_child(piece_body)
	piece_body.add_to_group("tetris_piece")
	tile_map_layer.add_to_group("tetris_blocks")
	piece_body.collision_layer = 1
	piece_body.collision_mask = 0
	# Position is already driven on physics ticks; apply it immediately.
	piece_body.sync_to_physics = false
	piece_body.set_meta("slam_active", false)
	active_piece_layer.collision_enabled = false
	# Ignore old scene-authored shapes so collision is not duplicated.
	for child in piece_body.get_children():
		if child is CollisionShape2D:
			child.disabled = true
	for i in 4:
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(tile_map_layer.tile_set.tile_size)
		shape.shape = rect
		shape.disabled = true
		piece_body.add_child(shape)
		_piece_shapes.append(shape)
	reset_board(true, false)
	_enter_ready_state()


func _enter_ready_state() -> void:
	game_state = GameState.WAITING_FOR_READY
	_player1_ready = false
	_player2_ready = false
	_cancel_active_piece()
	_pending_win = false
	if player_ref.has_method("reset_for_round"):
		player_ref.call("reset_for_round", _spawn_position)
	_update_ready_hud()
	_update_slam_cooldown_hud()


func _check_ready_input() -> void:
	if InputMap.has_action(player1_ready_action) and Input.is_action_just_pressed(player1_ready_action):
		_player1_ready = true
	if InputMap.has_action(player2_ready_action) and Input.is_action_just_pressed(player2_ready_action):
		_player2_ready = true
	_update_ready_hud()
	if _player1_ready and _player2_ready:
		_start_match()


func _start_match() -> void:
	if game_state != GameState.WAITING_FOR_READY:
		return
	game_state = GameState.PLAYING
	_hide_ready_hud()
	if player_ref.has_method("set_round_active"):
		player_ref.call("set_round_active", true)
	next_piece = _draw_from_bag()
	spawn_piece()
	match_started.emit()


func _physics_process(delta: float) -> void:
	if game_state == GameState.WAITING_FOR_READY:
		_check_ready_input()
		return
	if game_state != GameState.PLAYING:
		return
	# Goals take priority over a contact reported during the same tick.
	if _pending_win:
		_begin_round_end(true)
		return
	slam_cooldown_timer = maxf(0.0, slam_cooldown_timer - delta)
	_update_slam_cooldown_hud()
	if _pending_contact:
		_pending_contact = false
		_damage_player()
		if game_state != GameState.PLAYING:
			return
	if enable_floor_hazard:
		_check_floor_hazard()
		if game_state != GameState.PLAYING:
			return
	if current_piece.is_empty():
		return
	if _motion_active:
		_advance_motion(delta)
		return
	if _pending_move != 0:
		_try_move(Vector2i(clampi(_pending_move, -1, 1), 0))
		_pending_move = 0
	if _pending_rotate and not charging:
		_try_rotate(1)
	_pending_rotate = false
	if _pending_charge and slam_cooldown_timer <= 0.0 and not charging:
		charging = true
		charge_time = 0.0
		# A press and release can both happen between physics ticks.
		released_early = not Input.is_action_pressed("hard_drop")
		if charge_sfx:
			charge_sfx.play()
	_pending_charge = false
	if charging:
		charge_time += delta
		var ratio := clampf(charge_time / maxf(mega_charge_time, 0.01), 0.0, 1.0)
		active_piece_layer.self_modulate = Color(1.0, 1.0 - ratio * 0.8, 1.0 - ratio * 0.8)
		if charge_time >= maxf(mega_charge_time, telegraph_duration):
			_finish_charge(true)
		elif released_early and charge_time >= telegraph_duration:
			_finish_charge(false)
		return
	if not _fits(current_piece, rotation_state, piece_pos + Vector2i(0, 1)):
		lock_timer -= delta
		if lock_timer <= 0.0:
			_lock_piece()
			_shake_camera(gravity_lock_shake_duration, gravity_lock_shake_strength)
		return
	lock_timer = lock_delay
	fall_timer += delta
	var interval := maxf(fall_interval, 0.01)
	if Input.is_action_pressed("soft_drop"):
		interval /= maxf(soft_drop_multiplier, 1.0)
	if fall_timer >= interval:
		fall_timer = 0.0
		_begin_motion(piece_pos + Vector2i(0, 1), minf(normal_step_duration, interval))
		_advance_motion(delta)


func _unhandled_input(event: InputEvent) -> void:
	if game_state != GameState.PLAYING or _slamming:
		return
	if event.is_action_pressed("move_left"):
		_pending_move -= 1
	elif event.is_action_pressed("move_right"):
		_pending_move += 1
	elif event.is_action_pressed("rotate_cw"):
		_pending_rotate = true
	elif event.is_action_pressed("hard_drop") and not charging:
		_pending_charge = true
	elif event.is_action_released("hard_drop"):
		released_early = true


func _finish_charge(is_mega: bool) -> void:
	charging = false
	released_early = false
	if charge_sfx:
		charge_sfx.stop()
	_execute_hard_drop(is_mega)


func _execute_hard_drop(is_mega: bool = false) -> void:
	if game_state != GameState.PLAYING or current_piece.is_empty():
		return
	_slamming = true
	_mega_slam = is_mega
	# Cooldown starts even when the slam hits a player and destroys the piece.
	slam_cooldown_timer = maxf(slam_cooldown, 0.0)
	piece_body.set_meta("slam_active", true)
	active_piece_layer.self_modulate = Color.WHITE
	var target := piece_pos
	while _fits(current_piece, rotation_state, target + Vector2i(0, 1)):
		target += Vector2i(0, 1)
	_begin_motion(target, mega_drop_duration if is_mega else drop_visual_duration)
	if is_mega:
		if mega_slam_sfx:
			mega_slam_sfx.play()
	else:
		if slam_sfx:
			slam_sfx.play()


func _begin_motion(target: Vector2i, duration: float) -> void:
	_motion_from = tile_map_layer.map_to_local(piece_pos) - tile_map_layer.map_to_local(target)
	piece_pos = target
	_motion_offset = _motion_from
	_motion_elapsed = 0.0
	_motion_duration = maxf(duration, 0.01)
	_motion_active = true
	_update_active_piece_visual()


func _advance_motion(delta: float) -> void:
	var old_offset := _motion_offset
	_motion_elapsed += delta
	var progress := clampf(_motion_elapsed / _motion_duration, 0.0, 1.0)
	var new_offset := _motion_from.lerp(Vector2.ZERO, progress)
	# Sweep actual block rectangles BEFORE the collider pushes the player away.
	if _motion_hits_player(old_offset, new_offset):
		if _damage_player():
			return
	_motion_offset = new_offset
	_update_active_piece_visual()
	if progress >= 1.0:
		_motion_active = false
		if _slamming:
			var was_mega := _mega_slam
			_slamming = false
			piece_body.set_meta("slam_active", false)
			_lock_piece()
			_shake_camera(mega_shake_duration if was_mega else slam_shake_duration,
				mega_shake_strength if was_mega else slam_shake_strength)


func _queue_player_contact() -> void:
	# Signals can arrive during a physics query. Process damage on the board tick.
	if game_state == GameState.PLAYING:
		_pending_contact = true


func _on_player_squashed() -> void:
	_queue_player_contact()


func _damage_player() -> bool:
	if game_state != GameState.PLAYING or current_lives <= 0:
		return false
	if not player_ref.has_method("take_hit") or not bool(player_ref.call("take_hit")):
		return false
	current_lives = maxi(0, current_lives - 1)
	life_lost.emit(current_lives)
	_update_lives_hud()
	if squash_sfx:
		squash_sfx.play()
	_flash_screen_damage()
	_shake_camera(damage_shake_duration, damage_shake_strength)
	if current_lives == 0:
		lives_depleted.emit()
		if death_sfx:
			death_sfx.play()
		_begin_round_end(false)
	else:
		# Remove the attacking piece so it cannot pin the recovering player.
		_cancel_active_piece()
		spawn_piece()
	return true


func _check_floor_hazard() -> void:
	if not enable_floor_hazard:
		return
	var rect := _player_local_rect()
	var floor_y := float((grid_height - floor_hazard_rows) * tile_map_layer.tile_set.tile_size.y)
	if rect.end.y >= floor_y:
		_damage_player()


func _player_local_rect() -> Rect2:
	var shape := player_ref.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if not shape or not shape.shape:
		return Rect2()
	var transform_to_board := tile_map_layer.global_transform.affine_inverse() * shape.global_transform
	return transform_to_board * shape.shape.get_rect()


func _cell_rect(cell: Vector2i, offset: Vector2 = Vector2.ZERO) -> Rect2:
	var size := Vector2(tile_map_layer.tile_set.tile_size)
	return Rect2(tile_map_layer.map_to_local(cell) + offset - size * 0.5, size)


func _motion_hits_player(old_offset: Vector2, new_offset: Vector2) -> bool:
	var player_rect := _player_local_rect().grow(-0.25)
	if not player_rect.has_area():
		return false
	var cells := _get_world_cells(current_piece, rotation_state, piece_pos)
	for cell in cells:
		var before := _cell_rect(cell, old_offset)
		var after := _cell_rect(cell, new_offset)
		if _slamming:
			# Any actual slam overlap hurts. Per-cell sweep preserves shape gaps.
			if before.merge(after).intersects(player_rect):
				return true
		else:
			# Only EXPOSED underside faces can damage during a normal/soft drop.
			if cells.has(cell + Vector2i(0, 1)):
				continue
			var horizontal := player_rect.end.x > after.position.x + 0.5 and player_rect.position.x < after.end.x - 0.5
			if horizontal and player_rect.position.y >= before.end.y - 0.5 and player_rect.position.y <= after.end.y:
				return true
	return false


func _overlaps_player(piece: String, rot: int, pos: Vector2i) -> bool:
	var rect := _player_local_rect().grow(-0.5)
	for cell in _get_world_cells(piece, rot, pos):
		if _cell_rect(cell).intersects(rect):
			return true
	return false


func _try_move(dir: Vector2i) -> void:
	var target := piece_pos + dir
	if _fits(current_piece, rotation_state, target) and not _overlaps_player(current_piece, rotation_state, target):
		piece_pos = target
		_update_active_piece_visual()
		if move_sfx:
			move_sfx.play()


func _try_rotate(dir: int) -> void:
	var new_state := (rotation_state + dir + 4) % 4
	if _fits(current_piece, new_state, piece_pos) and not _overlaps_player(current_piece, new_state, piece_pos):
		rotation_state = new_state
		_update_active_piece_visual()
		# Do not scale the tile layer: that would detach it from its collider.
		if rotate_sfx:
			rotate_sfx.play()


func _lock_piece() -> void:
	if game_state != GameState.PLAYING or current_piece.is_empty():
		return
	var cells := _get_world_cells(current_piece, rotation_state, piece_pos)
	var kept_cells: Array = []
	var clear_rows := _goal_band_rows()
	var cleared := false
	for cell in cells:
		# Cells reaching the top disappear instead of blocking the goal/spawn.
		if cell.y < clear_rows:
			cleared = true
			continue
		grid[cell.y][cell.x] = current_piece
		tile_map_layer.set_cell(cell, block_source_id, TetrominoData.TILE_ATLAS_COORDS[current_piece])
		kept_cells.append(cell)
	_clear_goal_blocks()
	_cancel_active_piece()
	if lock_sfx:
		lock_sfx.play()
	if cleared and line_clear_sfx:
		line_clear_sfx.play()
	piece_locked.emit(kept_cells)
	spawn_piece()

func _cancel_active_piece() -> void:
	charging = false
	released_early = false
	charge_time = 0.0
	_motion_active = false
	_slamming = false
	_mega_slam = false
	_motion_offset = Vector2.ZERO
	_pending_contact = false
	_pending_move = 0
	_pending_rotate = false
	_pending_charge = false
	current_piece = ""
	if charge_sfx:
		charge_sfx.stop()
	if active_piece_layer:
		active_piece_layer.clear()
		active_piece_layer.position = Vector2.ZERO
		active_piece_layer.scale = Vector2.ONE
		active_piece_layer.visible = true
		active_piece_layer.self_modulate = Color.WHITE
	if piece_body:
		piece_body.set_meta("slam_active", false)
	for shape in _piece_shapes:
		shape.disabled = true


func reset_board(reset_lives: bool = true, auto_spawn: bool = true) -> void:
	_cancel_active_piece()
	grid.clear()
	for y in grid_height:
		var row: Array = []
		row.resize(grid_width)
		row.fill("")
		grid.append(row)
	tile_map_layer.clear()
	bag.clear()
	next_piece = ""
	if next_piece_layer:
		next_piece_layer.clear()
	slam_cooldown_timer = 0.0
	fall_timer = 0.0
	lock_timer = lock_delay
	if reset_lives:
		current_lives = maxi(1, starting_lives)
		lives_reset.emit(current_lives)
		_update_lives_hud()
	_update_slam_cooldown_hud()
	if auto_spawn and game_state == GameState.PLAYING:
		next_piece = _draw_from_bag()
		spawn_piece()


func spawn_piece() -> void:
	if game_state != GameState.PLAYING:
		return
	_clear_goal_blocks()
	_replace_piece_collider()
	if next_piece.is_empty():
		next_piece = _draw_from_bag()
	current_piece = next_piece
	next_piece = _draw_from_bag()
	rotation_state = 0
	piece_pos = Vector2i(grid_width / 2 - 2, 0)
	_motion_offset = Vector2.ZERO
	lock_timer = lock_delay
	fall_timer = 0.0
	if not _fits(current_piece, rotation_state, piece_pos):
		topped_out.emit()
		_cancel_active_piece()
		return
	_update_active_piece_visual()
	_update_next_piece_preview()


func _update_active_piece_visual() -> void:
	active_piece_layer.clear()
	active_piece_layer.position = _motion_offset
	if current_piece.is_empty():
		return
	var atlas: Vector2i = TetrominoData.TILE_ATLAS_COORDS[current_piece]
	for cell in _get_world_cells(current_piece, rotation_state, piece_pos):
		if cell.y >= 0:
			active_piece_layer.set_cell(cell, block_source_id, atlas)
	_sync_piece_collision()


func _sync_piece_collision() -> void:
	if not piece_body:
		return
	if current_piece.is_empty():
		for shape in _piece_shapes:
			shape.disabled = true
		return
	var origin_local := tile_map_layer.map_to_local(piece_pos)
	piece_body.position = origin_local + _motion_offset
	var offsets: Array = TetrominoData.SHAPES[current_piece][rotation_state]
	for i in _piece_shapes.size():
		var off: Vector2i = offsets[i]
		var cell := piece_pos + off
		_piece_shapes[i].position = tile_map_layer.map_to_local(cell) - origin_local
		_piece_shapes[i].disabled = cell.y < 0


func _request_win() -> void:
	if game_state == GameState.PLAYING:
		_pending_win = true


func _on_win_body_entered(body: Node2D) -> void:
	if body == player_ref:
		_request_win()


func _begin_death_reset() -> void:
	_begin_round_end(false)


func _begin_round_end(player_won: bool) -> void:
	if game_state != GameState.PLAYING:
		return
	game_state = GameState.CELEBRATING if player_won else GameState.COLLAPSING
	_round_serial += 1
	var serial := _round_serial
	_pending_win = false
	_pending_contact = false
	_hide_ready_hud()
	if charge_sfx:
		charge_sfx.stop()
	if player_ref.has_method("finish_round"):
		player_ref.call("finish_round", player_won)
	round_finished.emit(player_won)
	# Deferred so scene-connected physics signals may safely request an ending.
	_play_round_ending.call_deferred(player_won, serial)


func _play_round_ending(player_won: bool, serial: int) -> void:
	if player_won:
		await get_tree().create_timer(maxf(celebration_duration, 0.01)).timeout
	if serial != _round_serial or not is_inside_tree():
		return
	game_state = GameState.COLLAPSING
	# Capture sprites before clearing real collision. No moving solid board.
	_debris = Node2D.new()
	add_child(_debris)
	for cell in tile_map_layer.get_used_cells():
		_add_collapse_tile(tile_map_layer, cell)
	for cell in active_piece_layer.get_used_cells():
		_add_collapse_tile(active_piece_layer, cell)
	_cancel_active_piece()
	tile_map_layer.clear()
	if next_piece_layer:
		next_piece_layer.clear()
	if line_clear_sfx:
		line_clear_sfx.play()
	_round_tween = create_tween()
	_round_tween.tween_interval(maxf(collapse_duration, 0.01) + 0.15)
	await _round_tween.finished
	if serial == _round_serial:
		finish_death_reset()


func _add_collapse_tile(layer: TileMapLayer, cell: Vector2i) -> void:
	var source := layer.tile_set.get_source(layer.get_cell_source_id(cell)) as TileSetAtlasSource
	if not source:
		return
	var sprite := Sprite2D.new()
	var texture := AtlasTexture.new()
	texture.atlas = source.texture
	texture.region = Rect2(source.get_tile_texture_region(layer.get_cell_atlas_coords(cell)))
	sprite.texture = texture
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_debris.add_child(sprite)
	sprite.global_transform = layer.global_transform
	sprite.global_position = layer.to_global(layer.map_to_local(cell))
	var destination := sprite.position + Vector2(randf_range(-45, 45), float(grid_height * tile_map_layer.tile_set.tile_size.y) + 80.0)
	var tween := sprite.create_tween().set_parallel(true)
	tween.tween_property(sprite, "position", destination, maxf(collapse_duration, 0.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "rotation", randf_range(-2.0, 2.0), maxf(collapse_duration, 0.01))
	tween.tween_property(sprite, "modulate:a", 0.0, maxf(collapse_duration, 0.01)).set_delay(0.1)


func finish_death_reset() -> void:
	if game_state != GameState.COLLAPSING:
		return
	if is_instance_valid(_debris):
		_debris.queue_free()
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	if camera:
		camera.offset = Vector2.ZERO
	if _damage_flash_rect:
		_damage_flash_rect.color.a = 0.0
	reset_board(true, false)
	_enter_ready_state()


func _shake_camera(duration: float, strength: float) -> void:
	if not camera:
		return
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = create_tween()
	for i in maxi(1, int(duration / 0.02)):
		_shake_tween.tween_property(camera, "offset", Vector2(randf_range(-strength, strength), randf_range(-strength, strength)), 0.02)
	_shake_tween.tween_property(camera, "offset", Vector2.ZERO, 0.02)


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

func _draw_from_bag() -> String:
	if bag.is_empty():
		bag = TetrominoData.get_piece_names()
		bag.shuffle()
	return bag.pop_back()

func _update_next_piece_preview() -> void:
	if not next_piece_layer:
		return
	next_piece_layer.clear()
	if next_piece == "":
		return
	var atlas: Vector2i = TetrominoData.TILE_ATLAS_COORDS[next_piece]
	for offset in TetrominoData.SHAPES[next_piece][0]:
		next_piece_layer.set_cell(offset, block_source_id, atlas)

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
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_property(_damage_flash_rect, "color:a", 0.0, damage_flash_duration)

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

func _ensure_ready_hud() -> void:
	if _ready_hud_layer:
		return
	var layer := CanvasLayer.new()
	layer.layer = 95
	add_child(layer)
	var root := Control.new()
	layer.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	panel.offset_left = maxf(12.0, ready_hud_position.x)
	panel.offset_right = panel.offset_left + 250.0
	panel.offset_top = ready_hud_position.y
	panel.offset_bottom = ready_hud_position.y
	panel.custom_minimum_size = Vector2(250, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.045, 0.09, 0.94)
	style.border_color = Color(0.25, 0.9, 1.0)
	style.set_border_width_all(2)
	style.border_width_left = 5
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var arcade_font: Font = ready_hud_font
	if not arcade_font:
		var mono := SystemFont.new()
		mono.font_names = PackedStringArray(["Consolas", "DejaVu Sans Mono", "Liberation Mono", "monospace"])
		mono.font_weight = 800
		arcade_font = mono
	var title := Label.new()
	title.text = "GET READY"
	title.add_theme_font_override("font", arcade_font)
	title.add_theme_font_size_override("font_size", ready_hud_title_font_size)
	title.add_theme_color_override("font_color", Color(0.55, 1.0, 1.0))
	title.add_theme_color_override("font_shadow_color", Color(0.1, 0.25, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 3)
	box.add_child(title)
	box.add_child(HSeparator.new())
	_ready_p1_label = Label.new()
	_ready_p2_label = Label.new()
	for label in [_ready_p1_label, _ready_p2_label]:
		label.add_theme_font_override("font", arcade_font)
		label.add_theme_font_size_override("font_size", ready_hud_status_font_size)
		box.add_child(label)
	_ready_hud_layer = layer

func _update_ready_hud() -> void:
	_ensure_ready_hud()
	_ready_hud_layer.visible = true
	_ready_p1_label.text = "[OK] P1 READY" if _player1_ready else "[  ] P1 PRESS READY"
	_ready_p2_label.text = "[OK] P2 READY" if _player2_ready else "[  ] P2 PRESS READY"
	_ready_p1_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.65) if _player1_ready else Color(0.8, 0.85, 0.95))
	_ready_p2_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.65) if _player2_ready else Color(0.8, 0.85, 0.95))

func _hide_ready_hud() -> void:
	if _ready_hud_layer:
		_ready_hud_layer.visible = false

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



func _replace_piece_collider() -> void:
	# A reused moving body's jump back to the spawn point is interpreted as
	# platform velocity. Retire it so riders stay on the newly locked tiles.
	var body_name: StringName = piece_body.name
	var layers := piece_body.collision_layer
	var body_parent := piece_body.get_parent()
	body_parent.remove_child(piece_body)
	piece_body.queue_free()
	piece_body = AnimatableBody2D.new()
	piece_body.name = body_name
	piece_body.collision_layer = layers
	piece_body.collision_mask = 0
	piece_body.sync_to_physics = false
	piece_body.add_to_group("tetris_piece")
	piece_body.set_meta("slam_active", false)
	body_parent.add_child(piece_body)
	_piece_shapes.clear()
	for i in 4:
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(tile_map_layer.tile_set.tile_size)
		shape.shape = rect
		shape.disabled = true
		piece_body.add_child(shape)
		_piece_shapes.append(shape)


func _find_connected_win_area() -> void:
	if win_area:
		return
	for node in find_children("*", "Area2D", true, false):
		for connection in node.get_signal_connection_list("body_entered"):
			var callback: Callable = connection["callable"]
			if callback.get_object() == player_ref and callback.get_method() == &"_on_area_2d_body_entered":
				win_area = node as Area2D
				return


func _goal_band_rows() -> int:
	# At least four rows remain empty so all tetromino spawn shapes fit.
	var rows := maxi(4, goal_clear_rows)
	if is_instance_valid(win_area):
		for node in win_area.find_children("*", "CollisionShape2D", true, false):
			var shape := node as CollisionShape2D
			if shape.disabled or not shape.shape:
				continue
			var local_transform := tile_map_layer.global_transform.affine_inverse() * shape.global_transform
			var bounds: Rect2 = local_transform * shape.shape.get_rect()
			rows = maxi(rows, int(ceil(bounds.end.y / float(tile_map_layer.tile_set.tile_size.y))))
	return clampi(rows, 0, grid_height)


func _clear_goal_blocks() -> void:
	for y in range(_goal_band_rows()):
		for x in range(grid_width):
			grid[y][x] = ""
			tile_map_layer.erase_cell(Vector2i(x, y))
