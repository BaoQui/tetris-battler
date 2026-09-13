extends Node2D
class_name TetrisBoard

## Attach to a Node2D in your main scene, alongside a TileMap that shares
## the same cell_size. Assign player_path to the platformer character.
## Requires Input Map actions: move_left, move_right, rotate_cw, soft_drop,
## hard_drop (hard_drop is now held, not just tapped).

signal piece_locked(cells)
signal player_squashed
signal topped_out
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

# --- feel / difficulty knobs, tune these by playtesting ---
@export var fall_interval := 0.8     # seconds per auto-drop step
@export var soft_drop_multiplier := 8.0
@export var lock_delay := 0.5        # grace period once a piece touches down

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

# --- sfx, all optional — leave any of these empty in the Inspector to skip it ---
@export var move_sfx: AudioStreamPlayer
@export var rotate_sfx: AudioStreamPlayer
@export var charge_sfx: AudioStreamPlayer     # plays while holding hard_drop; stops the instant it resolves
@export var slam_sfx: AudioStreamPlayer
@export var mega_slam_sfx: AudioStreamPlayer  # tip: use the SAME clip as slam_sfx, just raise this node's Volume dB
@export var lock_sfx: AudioStreamPlayer       # plays on every lock, slam or not
@export var squash_sfx: AudioStreamPlayer

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
	player_squashed.connect(func():
		if squash_sfx:
			squash_sfx.play()
	)
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
	next_piece = _draw_from_bag()
	spawn_piece()


func _process(delta: float) -> void:
	if slam_cooldown_timer > 0.0:
		slam_cooldown_timer -= delta

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

	var grounded := not _fits(current_piece, rotation_state, piece_pos + Vector2i(0, 1))

	if grounded:
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
			# Squash is NOT checked here on purpose. Gating every fall step
			# on a squash check causes a standoff: if you're wedged under
			# the piece it returns true forever, and the piece never gets
			# permission to move again. PieceBody's real collision already
			# handles "pushed out of the way is safe" as it descends —
			# squash is only judged at the moments it actually matters:
			# when the piece comes to rest (_settle_or_squash) or on an
			# instant hard drop, both one-shot checks that can't loop.

	_update_active_piece_visual()


func _unhandled_input(event: InputEvent) -> void:
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
	while _fits(current_piece, rotation_state, drop_pos + Vector2i(0, 1)):
		drop_pos += Vector2i(0, 1)
	piece_pos = drop_pos
	_update_active_piece_visual()

	# Visual-only catch-up: snap the render node to where the piece started,
	# then tween it down. The logic already resolved instantly above (so
	# collision/squash timing is untouched) — this just makes the eye see a
	# fast fall instead of a teleport. Mega gets a snappier tween.
	# NOTE: piece_body snaps to the final resting spot immediately (it's
	# synced in _update_active_piece_visual above), so on a hard drop the
	# solid collider will be sitting at the bottom slightly before the
	# visual tween catches up. Only matters if a player is standing where
	# the piece lands mid-tween; worth a playtest, easy to live with.
	if active_piece_layer:
		var pixel_drop := (drop_pos.y - start_pos.y) * cell_size
		active_piece_layer.position.y = -pixel_drop
		var drop_duration := mega_drop_duration if is_mega else drop_visual_duration
		create_tween().tween_property(active_piece_layer, "position:y", 0.0, drop_duration)

	if _check_squash(current_piece, rotation_state, piece_pos):
		emit_signal("player_squashed")
		return

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


func _try_move(dir: Vector2i) -> void:
	if _fits(current_piece, rotation_state, piece_pos + dir):
		piece_pos += dir
		_update_active_piece_visual()
		if move_sfx:
			move_sfx.play()


func _try_rotate(dir: int) -> void:
	var new_state := (rotation_state + dir + 4) % 4
	if _fits(current_piece, new_state, piece_pos):
		rotation_state = new_state
		_update_active_piece_visual()
		_punch_scale(active_piece_layer, rotate_punch_amount, rotate_punch_duration)
		if rotate_sfx:
			rotate_sfx.play()
	# No wall-kick table — a rotation that doesn't fit is just blocked.


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
func _check_squash(piece: String, rot: int, pos: Vector2i) -> bool:
	if player_ref == null:
		return false
	var player_cells := _get_player_occupied_cells()
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


func _get_player_occupied_cells() -> Array:
	# Assumes the player has a CollisionShape2D with a RectangleShape2D.
	# Adjust get_rect() if your friend uses a CapsuleShape2D instead.
	var shape_node := player_ref.get_node("CollisionShape2D") as CollisionShape2D
	var extents: Vector2 = shape_node.shape.get_rect().size / 2.0
	var origin := _grid_origin()
	var top_left: Vector2 = player_ref.global_position - global_position - origin - extents
	var bottom_right: Vector2 = player_ref.global_position - global_position - origin + extents

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


func reset_board() -> void:
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
