extends CharacterBody2D
signal follow_platform(message)

@onready var raycast := $RayCast2D
var last_normal = Vector2.ZERO
var last_motion = Vector2.ZERO

var auto := false
func _ready():
	$Camera2D.current = true

func _process(_delta):
	floor_snap_length = Global.SNAP_FORCE
	constant_speed_on_floor = Global.CONSTANT_SPEED_ON_FLOOR
	slide_on_ceiling = Global.SLIDE_ON_CEILING
	stop_on_slope = Global.STOP_ON_SLOPE
	up_direction = Global.UP_DIRECTION
	move_max_angle = Global.MOVE_MAX_ANGLE
	floor_max_angle = Global.FLOOR_MAX_ANGLE
	update()

var UP_DIRECTION := Vector2.UP

func _physics_process(delta):
	linear_velocity = linear_velocity + Global.GRAVITY_FORCE * delta
	if Global.APPLY_SNAP:
		floor_snap_length = Global.SNAP_FORCE
	else:
		floor_snap_length = 0
	if Input.is_action_just_pressed('ui_accept') and (Global.INFINITE_JUMP or util_on_floor()):
		linear_velocity.y = linear_velocity.y + Global.JUMP_FORCE

	var speed = Global.RUN_SPEED if Input.is_action_pressed('run') and on_moving_surface else Global.NORMAL_SPEED
	var direction = _get_direction()
	if direction.x:
		linear_velocity.x = direction.x * speed
	elif util_on_floor():
		linear_velocity.x = move_toward(linear_velocity.x, 0, Global.GROUND_FRICTION)
	else:
		linear_velocity.x = move_toward(linear_velocity.x, 0, Global.AIR_FRICTION)

	if Input.is_action_just_pressed("ui_down"):
		auto = not auto
	if auto:
		linear_velocity.x = -Global.RUN_SPEED

	if Global.SLOWDOWN_FALLING_WALL and on_wall and linear_velocity.y > 0:
		var vel_x = linear_velocity.slide(Global.UP_DIRECTION).normalized()
		var dot = get_slide_collision(0).normalized().dot(vel_x)
		if is_equal_approx(dot, -1):
			linear_velocity.y = 70

	custom_move_and_slide()

var on_floor := false
var platform_rid :=  RID()
var platform_layer:int
var on_ceiling := false
var on_wall = false
var on_moving_surface = false
var floor_normal := Vector2.ZERO
var platform_velocity := Vector2.ZERO
var FLOOR_ANGLE_THRESHOLD := 0.01
var was_on_floor = false

class CustomKinematicCollision2D:
	var position : Vector2
	var normal : Vector2
	var collider : Object
	var collider_velocity : Vector2
	var travel : Vector2
	var remainder : Vector2
	var collision_rid: RID

	func get_collider_rid():
		return collision_rid

func custom_move_and_collide(p_motion: Vector2, p_infinite_inertia: bool = true, p_exclude_raycast_shapes: bool = true , p_test_only: bool = false, p_cancel_sliding: bool = true, exlude = []):
	var gt := get_global_transform()

	var margin = get_safe_margin()

	var result := PhysicsTestMotionResult2D.new()
	var colliding := PhysicsServer2D.body_test_motion(get_rid(), gt, p_motion, p_infinite_inertia, margin, result, p_exclude_raycast_shapes, exlude)

	var result_motion := result.motion
	var result_remainder := result.motion_remainder

	if p_cancel_sliding:

		var motion_length := p_motion.length()
		var precision := 0.001

		if colliding:
			# Can't just use margin as a threshold because collision depth is calculated on unsafe motion,
			# so even in normal resting cases the depth can be a bit more than the margin.
			precision = precision + motion_length * (result.collision_unsafe_fraction - result.collision_safe_fraction)

			if result.collision_depth > margin + precision:
				p_cancel_sliding = false

		if p_cancel_sliding:
			# When motion is null, recovery is the resulting motion.
			var motion_normal = Vector2.ZERO
			if motion_length > 0.00001:
				motion_normal = p_motion / motion_length

			# Check depth of recovery.
			var projected_length := result.motion.dot(motion_normal)
			var recovery := result.motion - motion_normal * projected_length
			var recovery_length := recovery.length()
			# Fixes cases where canceling slide causes the motion to go too deep into the ground,
			# Becauses we're only taking rest information into account and not general recovery.
			if recovery_length < margin + precision:
				# Apply adjustment to motion.
				result_motion = motion_normal * projected_length
				result_remainder = p_motion - result_motion

	if (not p_test_only):
		position = position + result_motion

	if colliding:
		var collision := CustomKinematicCollision2D.new()
		collision.position = result.collision_point
		collision.normal = result.collision_normal
		collision.collider = result.collider
		collision.collider_velocity = result.collider_velocity
		collision.travel = result_motion
		collision.remainder = result_remainder
		collision.collision_rid = result.collider_rid

		return collision
	else:
		return null

func custom_move_and_slide():
	var current_platform_velocity = platform_velocity
	if (on_floor or on_wall) and platform_rid.get_id():
		var excluded = (exclude_body_layers & platform_layer) != 0
		if not excluded:
			var bs := PhysicsServer2D.body_get_direct_state(platform_rid)
			if bs:
				current_platform_velocity = bs.linear_velocity
		else:
			current_platform_velocity = Vector2.ZERO

	was_on_floor = on_floor
	on_floor = false
	on_ceiling = false
	on_wall = false

	if not current_platform_velocity.is_equal_approx(Vector2.ZERO): # apply platform movement first
		custom_move_and_collide(current_platform_velocity * get_physics_process_delta_time(), infinite_inertia, true, false, false, [platform_rid])
		emit_signal("follow_platform", str(current_platform_velocity * get_physics_process_delta_time()))
	else:
		emit_signal("follow_platform", "/")

	var motion = linear_velocity * get_physics_process_delta_time()
	var motion_slided_up = motion.slide(up_direction)

	var prev_platform_velocity = current_platform_velocity
	var prev_floor_normal = floor_normal
	var prev_platform_rid: = platform_rid
	var prev_platform_layer = platform_layer

	platform_rid = RID()
	floor_normal = Vector2.ZERO
	platform_velocity = Vector2.ZERO

	# No sliding on first attempt to keep floor motion stable when possible.
	var sliding_enabled := not stop_on_slope or up_direction == Vector2.ZERO
	var first_slide := true
	var can_apply_constant_speed := sliding_enabled
	var last_travel := Vector2.ZERO

	for _i in range(max_slides):
		on_moving_surface = false
		var previous_pos = position
		
		var collision = custom_move_and_collide(motion, infinite_inertia, true, false, not sliding_enabled)
		if collision:
			last_normal = collision.normal # for debug
			_set_collision_direction(collision)

			if on_floor and stop_on_slope and ((motion.normalized() + up_direction).length() < 0.01):
				if collision.travel.length() > get_safe_margin():
					position = position - collision.travel.slide(up_direction)
				else:
					position = position - collision.travel
				linear_velocity = Vector2.ZERO
				motion = Vector2.ZERO
				break

			if collision.remainder.is_equal_approx(Vector2.ZERO):
				motion = Vector2.ZERO
				break
			# move on floor only checks
			if not on_moving_surface and on_wall and motion_slided_up.dot(collision.normal) < 0:
				# prevent to move against wall
				if was_on_floor and not on_floor and collision.travel.dot(up_direction) > 0 and linear_velocity.dot(up_direction) <= 0 : # prevent the move against wall
					position = position - up_direction * up_direction.dot(collision.travel) # remove the x from the vector when up direction is Vector2.UP
					on_floor = true
					platform_rid = prev_platform_rid
					platform_layer = prev_platform_layer
					platform_velocity = prev_platform_velocity
					floor_normal = prev_floor_normal
					linear_velocity = Vector2.ZERO
					motion = Vector2.ZERO
					break
				# prevent to move against wall on air
				elif sliding_enabled and not on_floor: # prevent to move against the wall in the air
					motion = up_direction * up_direction.dot(collision.remainder)
					motion = motion.slide(collision.normal)
				else:
					motion = collision.remainder
			# constant Speed when the slope is upward
			elif constant_speed_on_floor and util_on_floor_only() and can_apply_constant_speed and was_on_floor and motion.dot(collision.normal) < 0:
				can_apply_constant_speed = false
				var slide: Vector2 = collision.remainder.slide(collision.normal).normalized()
				if not slide.is_equal_approx(Vector2.ZERO):
					motion = slide * (motion_slided_up.length() - collision.travel.slide(up_direction).length() - last_travel.slide(up_direction).length())
			# prevent to move against wall
			elif (sliding_enabled or not on_floor) and not (on_ceiling and not slide_on_ceiling and linear_velocity.dot(up_direction) > 0):
				var slide_motion := collision.remainder.slide(collision.normal)
				if slide_motion.dot(linear_velocity) > 0.0:
					motion = slide_motion
				else:
					motion = Vector2.ZERO
				if slide_on_ceiling and on_ceiling:
					if linear_velocity.dot(up_direction) > 0:
						linear_velocity = linear_velocity.slide(collision.normal)
					else: # remove x when fall to avoid acceleration
						linear_velocity = up_direction * up_direction.dot(linear_velocity)
			else:
				motion = collision.remainder
				if on_ceiling and not slide_on_ceiling and linear_velocity.dot(up_direction) > 0:
					linear_velocity = linear_velocity.slide(up_direction)
					motion = motion.slide(up_direction)
			last_travel = collision.travel
		elif constant_speed_on_floor and first_slide and was_on_floor and not is_equal_approx(floor_snap_length, 0) and _on_floor_if_snapped():
			can_apply_constant_speed = false
			sliding_enabled = true # avoid to apply two time constant speed
			position = previous_pos
			var slide: Vector2 = motion.slide(prev_floor_normal).normalized()
			if not slide.is_equal_approx(Vector2.ZERO):
				motion = slide * (motion_slided_up.length())  # alternative use original_motion.length() to also take account of the y value
				collision = true
		can_apply_constant_speed = not can_apply_constant_speed and not sliding_enabled
		sliding_enabled = true
		first_slide = false

		# debug
		if not motion.is_equal_approx(Vector2.ZERO): last_motion = motion.normalized()

		if not collision or motion.is_equal_approx(Vector2.ZERO):
			break

	floor_snap()
	
	if not on_floor and not on_wall:
		linear_velocity = linear_velocity + current_platform_velocity # Add last floor velocity when just left a moving platform

	if on_floor and linear_velocity.dot(up_direction) <= 0:
		linear_velocity = linear_velocity.slide(up_direction)

func _set_collision_direction(collision):
	if(up_direction == Vector2.ZERO): return

	if acos(collision.normal.dot(up_direction)) <= move_max_angle + FLOOR_ANGLE_THRESHOLD:
		on_moving_surface = true

	if acos(collision.normal.dot(up_direction)) <= floor_max_angle + FLOOR_ANGLE_THRESHOLD:
		on_floor = true
		floor_normal = collision.normal
		platform_velocity = collision.collider_velocity
		if collision.collider.has_method("get_collision_layer"): # need a way to retrieve collision layer for tilemap
			platform_layer = collision.collider.get_collision_layer()
		platform_rid = collision.get_collider_rid()

	elif acos(collision.normal.dot(-up_direction)) <= floor_max_angle + FLOOR_ANGLE_THRESHOLD:
		on_ceiling = true
	else:
		platform_velocity = collision.collider_velocity
		if collision.collider.has_method("get_collision_layer"): # need a way to retrieve collision layer for tilemap
			platform_layer = collision.collider.get_collision_layer()
		platform_rid = collision.get_collider_rid()
		on_wall = true

func _on_floor_if_snapped():
	if up_direction == Vector2.ZERO or is_equal_approx(floor_snap_length, 0) or on_floor or not was_on_floor or linear_velocity.dot(up_direction) > 0: return false
	var collision := custom_move_and_collide(up_direction * -floor_snap_length, infinite_inertia, false, true)
	if collision:
		if acos(collision.normal.dot(up_direction)) <= floor_max_angle + FLOOR_ANGLE_THRESHOLD:
			return true

	return false

func floor_snap():
	if up_direction == Vector2.ZERO or is_equal_approx(floor_snap_length, 0) or on_floor or not was_on_floor or linear_velocity.dot(up_direction) > 0: return

	var collision := custom_move_and_collide(up_direction * -floor_snap_length, infinite_inertia, false, true)
	if collision:
		var collision_angle = acos(collision.normal.dot(up_direction))
		if collision_angle <= floor_max_angle + FLOOR_ANGLE_THRESHOLD:
			on_floor = true
			floor_normal = collision.normal
			platform_velocity = collision.collider_velocity
			if collision.collider.has_method("get_collision_layer"): # need a way to retrieve collision layer for tilemap
				platform_layer = collision.collider.get_collision_layer()
			platform_rid = collision.get_collider_rid()
			var travelled = collision.travel

			if collision_angle <= move_max_angle + FLOOR_ANGLE_THRESHOLD:
				on_moving_surface = true

			if stop_on_slope:
				# move and collide may stray the object a bit because of pre un-stucking,
				# so only ensure that motion happens on floor direction in this case.
				if travelled.length() > get_safe_margin() :
					travelled = up_direction * up_direction.dot(travelled)
				else:
					travelled = Vector2.ZERO

			position = position + travelled

func _process_collision(collision, p_up_direction, p_floor_max_angle):
	on_floor = false
	on_ceiling = false
	on_wall = false
	if acos(collision.normal.dot(p_up_direction)) <= p_floor_max_angle + FLOOR_ANGLE_THRESHOLD:
		on_floor = true
		floor_normal = collision.normal
		platform_velocity = collision.collider_velocity
		platform_layer = collision.collider.get_collision_layer()
		platform_rid = collision.get_collider_rid()

	elif acos(collision.normal.dot(-p_up_direction)) <= p_floor_max_angle + FLOOR_ANGLE_THRESHOLD:
		on_ceiling = true
	else:
		platform_velocity = collision.collider_velocity
		platform_layer = collision.collider.get_collision_layer()
		platform_rid = collision.get_collider_rid()
		on_wall = true

func _draw():
	var icon_pos : Vector2 = $icon.position
	icon_pos.y = icon_pos.y - 50
	draw_line(icon_pos, icon_pos + linear_velocity.normalized() * 50, Color.GREEN, 1.5)
	draw_line(icon_pos, icon_pos + last_normal * 50, Color.RED, 1.5)
	if last_motion != linear_velocity.normalized():
		draw_line(icon_pos, icon_pos + last_motion * 50, Color.ORANGE, 1.5)

func util_on_floor():
	return on_floor

func util_on_wall():
	return on_wall

func util_on_floor_only():
	return on_floor and not on_wall and not on_ceiling

func util_on_wall_only():
	return on_wall and not on_floor and not on_ceiling

func get_state_str():
	var state = []
	if on_ceiling:
		state.append("ceil")
	if on_floor:
		state.append("floor")
	if on_wall:
		state.append("wall")

	if state.size() == 0:
		state.append("air")
	return array_join(state, " & ")

func array_join(arr : Array, glue : String = '') -> String:
	var string : String = ''
	for index in range(0, arr.size()):
		string += str(arr[index])
		if index < arr.size() - 1:
			string += glue
	return string

func get_velocity_str():
	return "Velocity " + str(linear_velocity)

static func _get_direction() -> Vector2:
	var direction = Vector2.ZERO
	direction.x = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	direction.y = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	return direction
