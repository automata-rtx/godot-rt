# Measuring the ground truth occlusion

Everything here exists to answer one question with numbers instead of opinion: **is the ground
truth ambient occlusion actually computing ambient occlusion, and how far off is it?**

Screen-space occlusion has two independent sources of error, and comparing a render against a
single reference conflates them:

- what the **method** cannot know, because the camera never saw the occluder, and
- what the **implementation** gets wrong.

So there are two references.

| | what it traces | what the gap to it measures |
| --- | --- | --- |
| `ao_truth.py` | the real geometry, cosine-sampled | the ceiling: how close any screen-space method could get |
| `ao_screen_truth.py` | the same rays against a depth buffer built from the camera's own view | the implementation, with the method's blind spots held constant |

Both restate the scene, the camera and the sampling independently of the engine, so agreement with
a render is evidence rather than a tautology.

## The trick that makes a render measurable

`main.gd` renders with **ambient light only**, a fully rough non-specular white material, and no
direct light. A shaded pixel is then exactly `ambient * albedo * occlusion`, so dividing a render
by the same render with occlusion disabled recovers the occlusion term itself rather than something
the shading has already mixed. `ao_compare.py` does that division, undoing the sRGB transfer first.

`AO_SCENE` picks the scene. Each exists because the ones before it missed something.

- default: solid convex boxes on a large floor, viewed from above and outside.
- `thin`: a louvre of slats, a standing fin, a table on thin legs. The default scene is entirely
  solid and convex, which makes "everything behind the first occluder is also occluded"
  accidentally TRUE; a horizon march scores well there for the wrong reason and the visibility
  bitmask has nothing to win.
- `room`: a closed interior with the camera inside it, at 1280x720. Both of the others are open
  scenes viewed from above with a mean occlusion under one percent, so a *correct* occlusion barely
  enters the range the output transfer operates on -- 0.3 to 0.7 percent of those frames against 7
  percent of a room, which is why defects in that transfer went unseen for as long as they did. It
  is also the only scene that is not square, so it is the only one that can catch a defect that
  depends on the aspect ratio.

**Score the estimator AND what ships.** `main.gd` defaults to the identity transfer so
`ao_compare.py` can recover raw visibility by division, which measures the estimator. Run it again
with `AO_INTENSITY` and `AO_POWER` set to the values a project actually uses to measure what a
player sees. `ao_compare.py` prints the fraction of the frame below one 8-bit code alongside the
error columns, because a clipping transfer looks fine on every average and terrible on screen.

## Getting a binary

`run.sh` looks for `bin/godot.linuxbsd.editor.x86_64` at the repository root, or wherever
`GODOT_BIN` points. "Getting a binary" in `../shadow_validation/README.md` has the build line and
where the project's own builds come from.

## Running it

```
./run.sh room gtao          # the room scene, ground truth estimator
./run.sh room legacy        # the same scene, the estimator Godot has always shipped
./run.sh "" gtao            # the default solid-boxes scene
```

Each run writes `noao.png` and `ao.png` into `out/<scene>_<method>/` under Xvfb and lavapipe, which
is byte-for-byte deterministic. **The estimator is chosen per run rather than in `project.godot`**,
because scoring the two against each other needs both in one session and a project file can hold
only one answer; `main.gd` reads `AO_METHOD` before it builds the `Environment`, which matters
because the unity intensity depends on which estimator is active.

Then the references and the comparison, which are CPU traces and slower, so `run.sh` does not run
them for you:

```
python3 ao_truth.py 1.0 truth.npz                 # reference A, real geometry
python3 ao_screen_truth.py 1.0 0.3 screen.npz     # reference B, radius and thickness
python3 ao_compare.py truth.npz out/room_gtao/noao.png gtao=out/room_gtao/ao.png
```

`AO_SCENE`, `AO_RADIUS`, `AO_INTENSITY` and `AO_POWER` are the other knobs, passed through by
`run.sh` from the environment. The viewport size belongs to the scene, so `main.gd` sets it.
Set `AO_DIST_RADIUS` on either tracer to give every shading point the depth-scaled radius the
shipped default uses instead of a fixed world radius.

As a smoke test rather than a score: on the `room` scene the ground truth estimator comes back at a
mean visibility of about 0.94 with a minimum near 0.26, and the legacy one at about 0.98 with a
minimum near 0.77. Those are not targets -- the targets are in section 9 of `FORK_GUIDE.md` and come
from `ao_compare.py` against a traced reference -- but if a run produces two nearly identical
captures, or an `ao.png` no darker than its `noao.png`, something is wrong before any scoring starts.

The equivalent harness for shadows is `docs/rt_shadows/shadow_validation/`, which carries a "numbers
to reproduce" table this one does not yet have.

## gtao_sim.py

A faithful CPU model of the gather -- same projection terms, same sample pattern, same nearest
sampler behavior, same bitmask and sector weights, both radius branches, and `apply_transfer` for
the output curve. It exists because the loop of "edit shader, rebuild, software render, score"
takes minutes and this takes seconds, and because a disagreement between the two localizes a fault:
if the model and the shader disagree the shader has a plumbing bug, and if they agree but both miss
the reference the estimator itself is wrong. Every defect fixed so far was found that way, and it
has reproduced the engine to within 0.001 mean absolute error every time it has been checked.

`../FINDINGS.md` records what those measurements found, including the ideas that looked obvious and
did not survive being measured.
