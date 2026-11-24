# Changelog

All notable changes to Cameraman are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `CameramanPhysicsQueries`: the ray and shape cast shared by the third-person
  follow, the deoccluder and the third-person aim, giving the same result under
  GodotPhysics3D, Jolt Physics and Box3D Physics.
- `excluded_rids` on `CameramanObstacleAvoidance`, `CameramanDeoccluder` and
  `CameramanThirdPersonAim`: bodies skipped by RID, for collision that has no
  node to put in a group. Filled at run time; not saved.
- `docs/PHYSICS.md`: what a hit on a body without a node looks like, how the
  engines differ, and the measured path differences and query costs.
- `tests/physics_parity/`: a headless harness that runs every physics query
  the camera makes, the camera's path on scripted walks, and the query cost
  under each 3D physics engine, and compares them.

### Changed

- Collision with bodies that have no node (created directly on
  `PhysicsServer3D`, as a streamed world's baked collision is) is explicit: such
  a hit is solid and never matches a group.
- Ignored and transparent colliders are skipped by the hit's RID, so an ignored
  collider that is not a `CollisionObject3D` (CSG, GridMap) is skipped too.
- `CameramanDeoccluder` excludes the collision object its target belongs to,
  also when the target is a marker inside that body, and every collision object
  below the target. Before, only a target that was itself the body was excluded.
- `CameramanThirdPersonFollow` reuses one sphere shape for its casts.

### Fixed

- Under Box3D, a deoccluder whose target was inside the character's own body
  pulled the camera onto the target, and a third-person rig whose arm started
  inside geometry (a low ceiling) collapsed onto the character.
- `CameramanDeoccluder` stopped testing at the first ignored or transparent
  body, missing an occluder behind it and leaving `shot_quality` unset.
- `CameramanThirdPersonAim` stopped on an ignored collider that was not a
  `CollisionObject3D`.
- A third-person cast under Box3D left the camera's sphere about 5 mm inside
  the obstacle; the cast now steps back until it touches nothing.
- The 2D storyboard viewport test freed a viewport its `CanvasLayer` still
  used, which could crash the test run.

## [0.2.0] - 2026-09-06

### Added

- Confiner3D support for convex and concave camera volumes.
- Storyboard rendering in world-space and camera-space modes.
- A game-scale third-person demo with gameplay, camera managers, bridge and
  courtyard traversal, impulses, and shot sequences.
- Target-warp notification and cut-on-warp APIs through
  `CameramanCore.notify_target_warped()` and
  `CameramanBrain.cut_next_transition()`.
- A many-camera headless benchmark and registry sort-order caching.
- Editor tooling for custom node types, camera frustums, composer overlays,
  and atomic preset undo actions.

### Changed

- Improved third-person obstacle collision handling, target-body exclusion,
  shoulder sliding, minimum target distance, and close-camera presentation.
- Stabilized composition math when targets leave the camera frustum or occupy
  degenerate positions.
- Added corrected-position aiming across rotation, hard-look, pan/tilt, and
  position composition stages.

## [0.1.0]

### Added

- Initial Cameraman addon release for Godot 4.
- Core camera state, lens, blending, damping, registry, event, and target
  group types.
- 2D and 3D virtual cameras with brain-driven priority selection and blending.
- Follow, orbital, third-person, rotation, position, pan/tilt, noise, spline,
  and obstacle-avoidance components.
- Camera managers for ClearShot, State Driven, Sequencer, and Mixing workflows.
- Confiner, impulse, input-axis, storyboard, framing, deocclusion, and
  camera-attribute extensions.
- Editor node registration, demo scenes, automated GUT coverage, and CI
  validation.
