extends CharacterBody2D
signal squashed

# --- damage / invincibility ---
# hit_invincibility_time doubles as the debounce so a single prolonged
# contact (e.g. pinned in a corner) only counts once instead of firing
# every physics frame while touching — see take_hit().
@export var hit_invincibility_time: float = 1.0
@export var knockback_speed: float = 220.0       # horizontal pop away from the hit
@export var knockback_up_boost: float = 160.0    # small upward pop so it doesn't read as sliding into the floor
@export var blink_interval: float = 0.08         # half-cycle of the invincibility blink
var squash_lockout: float = 0.0
var _blink_tween: Tween
const SPEED = 120
const JUMP_VELOCITY = -350

@onready var coyote_timer: Timer = $CoyoteTimer
@onready var input_buffer_timer: Timer = $InputBufferTimer
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var ray_cast_2d: RayCast2D = $RayCast2D
@onready var walk_audio_player: AudioStreamPlayer2D = $SFX_HOLDER/WalkAudioPlayer



# Jump constants and variables
var wall_jump_lock: float = 0.0
const WALL_JUMP_LOCK_TIME: float = 0.18

var wall_contact_coyote: float = 0.0
const WALL_CONTACT_COYOTE_TIME: float = 0.2

var look_dir_x: int = 1
const WALL_JUMP_PUSH_FORCE: float = 250
const VELOCITY_WEIGHT_X: float = 0.10

var is_wall_sliding: bool = false
const GRAVITY_NORMAl: float = 14.5
const GRAVITY_WALL: float = 30
const WALLJUMP_VELOCITY = -350

# Dash constants and variables
const DASH_DISTANCE: float = 32.0
const DASH_TIME: float = 0.12
const DASH_SPEED: float = DASH_DISTANCE / DASH_TIME
const DASH_COOLDOWN: float = 0.5

var can_dash: bool = true
var dash_direction: int = 1
var dash_timer: float = 0.0
var dash_cooldown_timer: float = 0.0
var was_on_floor: bool = false

const spawn_visual_interval_dash: float = 0.06
const spawn_visual_interval_super_dash: float = 0.025
var spawn_visual_timer: float = 0.0

#Crouch Variables
var is_crouching: bool = false

# --- auto-unstuck ---
# How many times per physics frame we try to push out of an overlap. More
# than one pass matters when the player is pinched between two things at
# once (e.g. a locked block on one side and the floor on the other) —
# resolving the first contact can reveal the second, so a single pass isn't
# always enough to actually get free in one frame.
const UNSTUCK_MAX_PASSES: int = 4
# Extra distance added on top of the measured penetration depth, so the
# push actually clears the overlap instead of leaving the shapes exactly
# touching (which move_and_collide can still report as "colliding").
const UNSTUCK_PUSH_MARGIN: float = 0.5


func _physics_process(delta: float) -> void:
	# Gravity is skipped during a dash.
	if not is_on_floor() and dash_timer == 0.0:
		var gravity = get_gravity()
		velocity += gravity * delta
		velocity += gravity * 0.75 * delta

	# Crouch is purely key-driven now — it no longer un-crouches itself
	# based on the ceiling raycast. change_collision() is what refuses to
	# grow the hitbox into a ceiling; is_crouching itself just reflects
	# whether the key is held.
	is_crouching = Input.is_action_pressed("crouch") && is_on_floor()
	var direction := Input.get_axis("player_left", "player_right")

	_jump(delta, direction)

	if wall_jump_lock <= 0.0 and dash_timer == 0.0:
		if direction > 0:
			animated_sprite.flip_h = false
			velocity.x = direction * SPEED
		elif direction < 0:
			animated_sprite.flip_h = true
			velocity.x = direction * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)

		if direction and wall_contact_coyote == 0.0 and not is_on_wall():
			look_dir_x = int(direction)

	_dash_logic(delta)
	movement_audio()
	move_and_slide()

	# --- ADD THIS BLOCK ---
	if squash_lockout > 0.0:
		squash_lockout -= delta

	# is_on_ceiling() plus checking WHAT we hit is the reliable way to know
	# a falling piece landed on our head, now that pieces are solid. Grid
	# math can't see this anymore — physics resolves the push before a
	# cell-overlap check would ever see the two occupy the same cell.
	if squash_lockout <= 0.0 and is_on_ceiling():
		for i in get_slide_collision_count():
			var collision := get_slide_collision(i)
			var collider := collision.get_collider()
			if collider and collider.is_in_group("tetris_piece"):
				# Just report the contact. board.gd's _on_player_squashed()
				# calls take_hit() below in response to this same signal
				# (synchronously, same frame) — that's what actually sets
				# squash_lockout, so by next frame this check is gated.
				# Setting the lockout here too would double-gate against
				# board.gd's own damage sources (floor hazard, grid
				# backup) which never pass through this loop at all.
				squashed.emit()
				break
	# ----------------------

	_finish_dash_frame(delta)
	change_collision(direction)
	_resolve_stuck_overlap()
	update_animations(direction)
	wall_slide(delta)

func _jump(delta, direction):
	if wall_jump_lock > 0.0:
		wall_jump_lock = maxf(0.0, wall_jump_lock - delta)

		if dash_timer == 0.0:
			velocity.x = lerp(
				velocity.x,
				direction * SPEED / 2,
				VELOCITY_WEIGHT_X * 0.5
			)
	elif dash_timer == 0.0:
		velocity.x = lerp(
			velocity.x,
			direction * SPEED / 2,
			VELOCITY_WEIGHT_X
		)

	if Input.is_action_just_pressed("player_jump"):
		input_buffer_timer.start()

	if is_on_floor():
		# Landing resets the dash cooldown.
		if not was_on_floor:
			dash_cooldown_timer = 0.0

		coyote_timer.start()

		if dash_timer == 0.0 and dash_cooldown_timer == 0.0 and not can_dash:
			can_dash = true

	was_on_floor = is_on_floor()

	# Prevent jumping from changing the dash direction or velocity.
	if dash_timer > 0.0:
		return

	if (
		not is_on_floor()
		and wall_contact_coyote > 0.0
		and Input.is_action_just_pressed("player_jump")
	):
		velocity.x = -look_dir_x * WALL_JUMP_PUSH_FORCE
		velocity.y = WALLJUMP_VELOCITY

		look_dir_x = -look_dir_x
		wall_jump_lock = WALL_JUMP_LOCK_TIME
		wall_contact_coyote = 0.0

		coyote_timer.stop()
		input_buffer_timer.stop()

	elif not input_buffer_timer.is_stopped() and not coyote_timer.is_stopped():
		velocity.y = JUMP_VELOCITY
		coyote_timer.stop()
		input_buffer_timer.stop()

	elif not is_on_floor():
		if Input.is_action_just_released("player_jump"):
			velocity.y *= 0.70


func wall_slide(delta):
	# Wall sliding cannot change velocity during a dash.
	if dash_timer > 0.0:
		is_wall_sliding = false
		wall_contact_coyote = maxf(wall_contact_coyote - delta, 0.0)
		return

	is_wall_sliding = (
		not is_on_floor()
		and velocity.y > 0
		and is_on_wall()
		and (
			Input.is_action_pressed("player_left")
			or Input.is_action_pressed("player_right")
		)
	)

	if is_wall_sliding:
		look_dir_x = -int(get_wall_normal().x)
		wall_contact_coyote = WALL_CONTACT_COYOTE_TIME
		velocity.y = GRAVITY_WALL
	else:
		wall_contact_coyote = maxf(wall_contact_coyote - delta, 0.0)


func update_animations(direction):
	if is_on_floor():
		if direction == 0:
			if is_crouching:
					animated_sprite.play("crouch")
			else:
				animated_sprite.play("default")
		else:
			if is_crouching:
				animated_sprite.play("crouch_walk")
			else:
				animated_sprite.play("walk")
	else:
		if wall_contact_coyote > 0:
			animated_sprite.play("wall_slide")
		else:
			animated_sprite.play("jump" if velocity.y < 0 else "fall")
			


func change_collision(direction):
	if is_crouching:
		collision_shape.position = Vector2(float(look_dir_x), 8.5)
		collision_shape.shape.size = Vector2(8.0, 11.0)
	elif animated_sprite.animation == "jump":
		collision_shape.position = Vector2(float(look_dir_x), -3.5)
		collision_shape.shape.size = Vector2(8.0, 9.0)
	elif check_above():
		# Key says "stand up" but there's a ceiling right above the crouch
		# hitbox — hold the crouch shape instead of growing straight into
		# solid geometry (this is what used to leave the player wedged
		# into a block the instant they released crouch under a low gap).
		collision_shape.position = Vector2(float(look_dir_x), 8.5)
		collision_shape.shape.size = Vector2(8.0, 11.0)
	else:
		collision_shape.position = Vector2(float(look_dir_x), 3.5)
		collision_shape.shape.size = Vector2(8.0, 21.0)

func _dash_logic(delta: float) -> void:
	if dash_cooldown_timer > 0.0:
		dash_cooldown_timer = maxf(0.0, dash_cooldown_timer - delta)

	if can_dash and Input.is_action_just_pressed("player_dash"):
		can_dash = false
		dash_timer = DASH_TIME
		dash_cooldown_timer = DASH_COOLDOWN

		# Keep this direction throughout the dash.
		dash_direction = look_dir_x

	if dash_timer > 0.0:
		# Scale the final frame to keep total movement at 32 pixels.
		var frame_fraction: float = minf(1.0, dash_timer / delta)
		velocity.x = DASH_SPEED * dash_direction * frame_fraction
		velocity.y = 0.0


func _finish_dash_frame(delta: float) -> void:
	if dash_timer <= 0.0:
		return

	dash_timer = maxf(0.0, dash_timer - delta)

	# A wall stops the dash early.
	if is_on_wall():
		dash_timer = 0.0

	# Remove dash momentum when finished.
	if dash_timer == 0.0:
		velocity.x = 0.0
func check_above() -> bool:
	return ray_cast_2d.is_colliding() 
	
func movement_audio():
	walk_audio_player.pitch_scale = .8
	if abs(velocity.x) > 0 && (is_on_floor()) && is_crouching == false:
		if not walk_audio_player.playing: 
			walk_audio_player.play()


## Safety net for the leftover stuck cases that aren't about crouching at
## all: a newly-locked block landing partway inside the player (only the
## TOP row of a piece counts as a squash on the board's side, so a piece
## can legally lock while overlapping the player's feet/torso), a shape
## swap that lands in solid geometry, or getting pinched between a wall
## and a falling piece. move_and_collide with zero motion and test_only
## reports whether the current shape is overlapping anything without
## actually moving it, plus the real penetration depth via get_depth() —
## so instead of guessing a fixed nudge amount, we push exactly far enough
## to clear it. Looping a few times per frame handles being squeezed from
## two directions at once, where clearing one contact reveals the other.
func _resolve_stuck_overlap() -> void:
	for i in UNSTUCK_MAX_PASSES:
		var collision := move_and_collide(Vector2.ZERO, true)
		if not collision:
			break
		var push_distance: float = collision.get_depth() + UNSTUCK_PUSH_MARGIN
		global_position += collision.get_normal() * push_distance


## Central entry point for ANY damage source — the piece-contact check
## above, or board.gd's grid-backup / floor-hazard / hard-drop squashes,
## which never touch this script's own collision check at all. Returns
## false (and does nothing) if we're still invincible from a previous hit;
## that's the single gate that stops those sources from chain-hitting the
## player frame after frame while the blink is still playing. On a real
## hit: starts the invincibility window, knocks the player away from
## wherever they got hit so they're not left stuck in place, and starts
## the Mario-style blink for the duration of the window.
func take_hit(knockback_dir: Vector2 = Vector2.ZERO) -> bool:
	if squash_lockout > 0.0:
		return false
	squash_lockout = hit_invincibility_time
	flash_hurt()
	_apply_knockback(knockback_dir)
	_start_invincibility_blink()
	return true


## No direction supplied (the common case — a piece landing square on top,
## or a floor hazard) just pops the player opposite whichever way they're
## currently facing, so a hit never leaves them drifting straight back into
## whatever just hit them. A caller with real hit geometry can still pass
## an explicit direction.
func _apply_knockback(dir: Vector2) -> void:
	var push_dir := dir
	if push_dir == Vector2.ZERO:
		push_dir = Vector2(-look_dir_x, 0)
	push_dir = push_dir.normalized()
	velocity.x = push_dir.x * knockback_speed
	velocity.y = -knockback_up_boost


## Fades the sprite's alpha in and out for the whole invincibility window —
## the "Mario" blink — instead of the quick color flash below, so it's
## visible for exactly as long as the player actually can't be hit again.
## Runs on self_modulate (alpha only) rather than modulate — flash_hurt()
## below animates modulate's color, and two tweens driving the same
## property fight each other and flicker; self_modulate is a genuinely
## separate CanvasItem property, so both can run at once and just
## multiply together (a red flash that fades in and out for a second).
## Built as explicit tween steps sized to hit_invincibility_time rather
## than Tween.set_loops(), so a trailing reset-to-opaque step can run
## once, after the loop, without also repeating on every cycle.
func _start_invincibility_blink() -> void:
	if not animated_sprite:
		return
	if _blink_tween and _blink_tween.is_valid():
		_blink_tween.kill()
	animated_sprite.self_modulate.a = 1.0
	_blink_tween = create_tween()
	var cycles := maxi(1, int(hit_invincibility_time / (blink_interval * 2.0)))
	for i in cycles:
		_blink_tween.tween_property(animated_sprite, "self_modulate:a", 0.25, blink_interval)
		_blink_tween.tween_property(animated_sprite, "self_modulate:a", 1.0, blink_interval)
	_blink_tween.tween_callback(func(): animated_sprite.self_modulate.a = 1.0)


## Quick, obvious hit-flash on the sprite — a red/white blink rather than a
## single fade, since a one-shot tween back to white read as "barely
## noticeable" in testing. Public (no underscore) so board.gd can call this
## directly for damage sources it detects itself (bottom hazard, grid-level
## squash backup) that never touch this script's own squash-detection path.
## Animates modulate (color), NOT self_modulate — see the blink above for
## why that separation matters. Runs alongside the blink every time, called
## from take_hit(), so a hit always reads as "red pulse, then blinking".
func flash_hurt() -> void:
	if not animated_sprite:
		return
	var hurt_color := Color(1.0, 0.15, 0.15)
	var tween := create_tween()
	tween.tween_property(animated_sprite, "modulate", hurt_color, 0.05)
	tween.tween_property(animated_sprite, "modulate", Color.WHITE, 0.05)
	tween.tween_property(animated_sprite, "modulate", hurt_color, 0.05)
	tween.tween_property(animated_sprite, "modulate", Color.WHITE, 0.05)
