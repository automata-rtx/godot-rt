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

`AO_SCENE=thin` swaps in a second scene of thin geometry -- a louvre of slats, a standing fin, a
table on thin legs. It exists because the default scene is entirely solid and convex, which makes
"everything behind the first occluder is also occluded" accidentally TRUE; a horizon march scores
well there for the wrong reason, and the visibility bitmask has nothing to win.

## Running it

```
python3 ao_truth.py 1.0 truth.npz                 # reference A, real geometry
python3 ao_screen_truth.py 1.0 0.25 screen.npz    # reference B, radius and thickness
python3 ao_compare.py truth.npz noao.png gtao=with_ao.png
```

Renders come from a project holding `main.gd` and `main.tscn`, with `RT_TEST_OUT` set to the output
path and `AO_OFF=1` for the divisor. `AO_RADIUS`, `AO_INTENSITY` and `AO_SCENE` are the other knobs.
Set `AO_DIST_RADIUS` on either tracer to give every shading point the depth-scaled radius the
shipped default uses instead of a fixed world radius.

## gtao_sim.py

A faithful CPU model of the gather -- same projection terms, same sample pattern, same sampler
behavior, same bitmask. It exists because the loop of "edit shader, rebuild, software render,
score" takes minutes and this takes seconds, and because a disagreement between the two localizes a
fault: if the model and the shader disagree the shader has a plumbing bug, and if they agree but
both miss the reference the estimator itself is wrong. Both of the defects fixed here were found
that way.
