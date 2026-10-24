# AMD GI source-domain proofs

These checks preserve the numerical and ownership evidence used in
[the adapter decisions](../../AMD_GI_ADAPTER_DECISIONS.md). They are source-checked
CPU counterexamples or algebra checks, **not executions of AMD's GPU renderer**.
The firefly snapshot proof records a withdrawn proposal; passing it does not make
that proposal approved or establish a lighting improvement.

Use Capsaicin commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452` and set
`AMD_CAPSAICIN_ROOT` to its checkout. Run each Python file directly with Python 3;
`check_native_motion.py` also needs NumPy, and `check_normal_spaces.py` needs `g++`.
The normal check writes generated source/output below `AMD_GI_PROOF_OUT`
(default `/tmp/amd-gi-source-proofs`). Other checks print JSON to standard output.
GPU fixtures and image scorers are separately documented in [VALIDATION.md](../../VALIDATION.md).
