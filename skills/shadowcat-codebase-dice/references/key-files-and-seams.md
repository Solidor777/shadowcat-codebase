Part of the shadowcat-codebase-dice skill; read it before editing any file under src/server/src/dice/.

# Dice engine: key files and seams

Per-module entries for dice::rng, spec, outcome, eval (groups, classify, crit, expertise, sum, success), recalc and notation, with the seams between them.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-rng-spec-outcome-eval.md](key-files-and-seams-01-rng-spec-outcome-eval.md) | Key files & seams: `dice::rng`; `dice::spec`; `dice::outcome`; `dice::eval::groups`; `dice::eval`; `dice::eval::classify`; `dice::eval::crit` | Editing the rng, the `dice::spec` AST, roll outcomes, group resolution, classification or crit handling |
| [key-files-and-seams-02-expertise-sum-recalc-notation.md](key-files-and-seams-02-expertise-sum-recalc-notation.md) | Key files & seams: `dice::eval::expertise`; `dice::eval::sum`; `dice::eval::success`; `dice::recalc`; `dice::notation` | Editing expertise allocation, total or success evaluation, recalculation or the notation lexer and parser |
