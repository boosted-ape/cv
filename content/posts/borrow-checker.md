---
title: I Wrote a Borrow Checker for a Tiny Subset of C++
date: 2026-11-15
summary: "I wanted to know what a borrow proof is actually worth, so I built a closed-world checker for a toy C++ dialect and turned the proofs into LLVM noalias. Terrible idea. Would do again."
tags:
  - compilers
  - c++
  - rust
  - llvm
---

*The whole thing started with an unreasonable question: could I give C++ the borrow checker it so clearly does not want?*

Borrow checking looks like a type system problem until you try to add it to C++. Rust gets to define aliasing as part of the language. C++ shows up with pointers, references, `const`, copy constructors, destructors, inheritance, casts, and decades of code that assumes any two of those can alias.

I could have spent the entire project writing special cases, and I still would not have been able to tell you what "accepted" meant.

So I didn't write a borrow checker for C++. I wrote one for a small, opt-in dialect of C++ — and made the boundary part of the design.

The project is called `safe_cpp`. A translation unit opts in with:

```cpp
#pragma safe_cpp
```

Every file in the program must carry the pragma. The checker treats the supplied files as one closed world: every called user function has a body in those files, every type and global fits the modeled subset, and there is exactly one zero-argument `int main()`. Anything outside the subset is rejected before it can be reported as a success.

Sounds restrictive? It is.

But it buys the thing a general C++ analyzer usually cannot give you — a precise definition of what the checker is claiming. A clean result means "this represented program follows my policy," not "all of C++ is safe."

Everything else in the project followed from that one decision.

## Step one: admit you can't check C++

My first version was mostly a list of things I refused to model.

Raw pointers were out. So were pointer, reference, and array fields; address-taking; member pointers; arrays and subscripting; globals and statics; thread-local storage; virtual methods; inheritance; templates; lambdas; exceptions; indirect calls; manual `new` and `delete`; alias-forging casts; user-defined copy/move operations; and most operator overloading.

A few things made the cut: scalars, ordinary records, local references, direct calls with visible bodies, branches, loops, field projections, moves, drops, and a small runtime surface for output. Later I added body-defined constructors and member initializer lists, because classes were too awkward to demo without them.

The list itself is not the interesting part. The order of operations is:

1. Parse the marked translation units.
2. Lower the supported Clang AST into my own MIR.
3. Reject anything the MIR cannot represent.
4. Verify the MIR.
5. Borrow-check the MIR.
6. Only then report success, print MIR, or lower to LLVM IR.

That ordering is the difference between a checker and a linter. A linter can skip a construct and still print a warning count. A checker that misses a construct can accept a program for the wrong reason. And once the checker says OK, the borrow information becomes the justification for optimization attributes later. There is no room for "probably fine."

The closed world also deleted an entire category of problems. I never had to model external function bodies, lifetime annotations on declarations, or ABI behavior across unanalyzed code. A call without a body is a rejection, not a trust decision. Blunt, but honest.

## What the checker actually sees

Clang hands me an AST, but the borrow checker never touches it directly. A visitor lowers the AST into a small control-flow MIR with basic blocks, statements, terminators, local declarations, and drops.

The central pieces are:

- **Place** — a local plus a sequence of projections, like `x`, `x.field`, or `(*r).field`.
- **Loan** — a borrow created at a particular MIR point, with an origin and a region.
- **Origin** — the place or value a loan came from. It's what lets me ask whether two references are derived from the same thing.
- **Region** — the set of MIR points where a loan is live.
- **Local metadata** — type, mutability, initialization state, drop obligation, and, for reference locals, the origin and region they represent.

A reference is not just a value of reference type. In MIR it carries a loan identity. That's the difference between "the borrow of `bank`" and "some pointer."

The type model stayed deliberately narrow: scalars, records with fields, references, and parameter types. Pointers are rejected by policy. References are first-class values in MIR, but they're tracked loans rather than arbitrary addresses.

This MIR is not rustc's. It's smaller, and shaped around what this checker can actually prove. That was intentional: a smaller IR is easier to verify, easier to test, and dramatically easier to lower to LLVM.

## The rules, in plain English

The checker follows an NLL-style model, but it's an ad-hoc point-set implementation, not a copy of rustc.

Liveness seeds regions. For each local, the checker computes the MIR points where the local is live. A loan's region starts at its creation point and is constrained by uses, assignments, calls, reborrows, and returns. The solver propagates those constraints to a fixed point.

Then the rules are mostly what you'd expect:

- A **shared loan** permits reads, other shared loans, and shared reborrows.
- A **mutable loan** is exclusive. A read, write, move, drop, or overlapping loan while it's live is rejected.
- A loan ends at its last use, not at the end of the block. A write after the last use is accepted; a write before it is rejected.
- A reborrow is allowed, but using the parent while the child is still live is rejected.
- Moving out of a borrowed place, moving while a loan is live, and dropping while a loan is live are rejected.
- Field projections are field-sensitive: mutable loans of disjoint fields are accepted, while a loan of the whole aggregate overlaps its fields.
- Shared references are copyable. Mutable references and non-copyable records are affine.
- A mutable method receiver that returns `*this` returns a borrow of the receiver; later writes through the receiver conflict until that returned reference's last use.

The part that ate the most iterations was not the basic shared/mutable rule. It was making the region solver agree with the call and return behavior I wanted.

## Two-phase borrows, or why `bank.deposit(bank.balance())` should work

Method calls create an awkward ordering problem.

In a call like:

```cpp
bank.deposit(bank.balance());
```

the receiver is reserved before the arguments are evaluated, but the method body doesn't run until after the arguments are evaluated. During that window, evaluating `bank.balance()` needs shared access to `bank`. The receiver reservation itself is not yet a mutable activation.

The checker models this as a two-phase borrow for mutable method receivers:

- The receiver gets a **reservation** at the call site.
- Shared reads are allowed while the reservation is pending.
- Mutable access and moves are not.
- The reservation **activates** when the call happens.
- The call's result borrow is treated as a continuation of the activation loan, not a second conflicting loan.

That last point is the subtle one. If the activation call creates a new unrelated loan, the solver can report a conflict with the reservation that's still live at the activation point. If it treats the activation as a continuation of the same borrow, the two-phase story stays consistent.

I also had to make sure the solver didn't accidentally extend the reservation over the whole function. A reservation shouldn't keep a borrow alive past the call just because the region solver found a path through the activation. Fixing that removed a class of false conflicts without making the checker more permissive anywhere else.

Two-phase support currently covers mutable method receivers only. It's not a general model for every borrow-producing expression. That limitation is documented, and the checker rejects, or conservatively rejects, the cases it cannot represent.

## Returns are where soundness gets interesting

A function can return a reference, and the checker has to know where that reference came from, because the caller's borrow checking depends on it.

For example:

```cpp
int& first(int& a, int& b) {
    return a;
}
```

The result of `first(x, y)` is a borrow of `x`, not a fresh loan unrelated to the arguments. The checker infers return origins from function bodies and propagates them through the call graph. If several reference parameters can reach the return, it keeps their union.

If a returned reference is not rooted in a parameter, the checker rejects the function. That rules out returning a reference to a local — a dangling reference in the modeled subset.

This matters a lot for LLVM later. A returned reference is not the same as "a pointer that does not alias any argument." A function like `id(x)` returns `x` itself, so LLVM's return `noalias` would be a false claim. The correct lowering gives the return `nonnull` only, and lets the caller's borrow information handle exclusivity. That distinction saved me from emitting an unsound attribute.

## Drops, moves, and the long tail

Dropping is not just a call to a destructor. It's a use of the place, and it interacts with borrows.

The checker tracks whether a local is uninitialized, initialized, or moved from. Locals are destroyed at scope exit in reverse construction order. Temporaries are destroyed at the end of their full expression, with an approximation: temporary drops are attached per Clang statement, and a temporary bound to a reference is extended to the enclosing block. The approximation can run a drop later than C++ requires, but never earlier. That's documented rather than hidden.

Destructor effects are summarized. A body-defined destructor is analyzed when it's representable; an implicit destructor, or one whose body is missing, falls back to a conservative write of the whole dropped place. A conservative summary can reject valid code, but it never invents aliasing freedom.

Moves out of projected fields are rejected until field-sensitive move paths exist. A second move in one expression is diagnosed as a double move rather than a generic use-before-initialization. Those diagnostics are part of the model: the checker should say which rule it thinks you broke.

## A class example that hits everything at once

The class example in `examples/classes/classes.cpp` exercises the parts that interact most: a body-defined constructor, a member initializer list, mutating and const methods, a two-phase call, a method returning `Bank&`, a method returning `int&`, a default constructor with a body, and a destructor.

Running it through the checker:

```sh
./build/mir-builder examples/classes/classes.cpp \
  --emit=mir -- -std=c++17
```

prints the lowered MIR and ends with a profile line. Compiling and running it through the backend:

```sh
./build/mir-builder examples/classes/classes.cpp \
  --emit=exe -o /tmp/classes -- -std=c++17

/tmp/classes
```

gives you:

```text
balance=150 deposits=2 withdrawals=1 got=30 denied=0 counter=1
logger 7 dropped
```

That output is not the interesting part. The interesting part is that the same run produced borrow facts good enough to justify alias attributes on the generated LLVM IR.

## From proof to performance

The LLVM backend runs only after MIR verification and borrow checking succeed. It lowers the checked MIR subset to a standalone LLVM module. It is not a general C++ ABI backend; record layout is the backend's own layout, and the module is self-contained. The point is to show what the borrow proof is worth, not to replace Clang's code generator.

The attribute mapping is small:

| MIR fact | LLVM attribute | Why |
|---|---|---|
| `&mut T` parameter | `noalias nonnull` | the callee has the only access to the referent |
| `&T` parameter | `readonly nonnull` | the callee never writes through the reference |
| reference return | `nonnull` only | the return may be derived from an argument |
| non-const `this` | `noalias nonnull` | the receiver borrow is exclusive for the call |
| const `this` | `readonly nonnull` | the receiver is not written through |
| all functions | `nounwind` | exceptions are outside the dialect |

`noalias` is never attached to a shared reference. Several `&T` values may legitimately point to the same object. A mutable argument gets `noalias` because the borrow checker rejected every conflicting access or loan while it was live, including two-phase receiver reservations.

The return case is deliberately conservative. Return `noalias` would say "the result does not alias any argument pointer." A function that returns a reference derived from its argument violates that claim by construction. Rust's caller-side NLL makes the caller's borrow exclusive; LLVM's return attribute is a different statement about the pointer value itself. They are not interchangeable.

## The optimization that made the proof visible

The clearest demonstration is `examples/safe_cpp_llvm/noalias.cpp`:

```cpp
int scale(int& acc, const int& step, int n) {
    for (int i = 0; i < n; ++i)
        acc += step;
    return acc;
}
```

Native C++ cannot assume `acc` and `step` don't alias. Clang 22 on my machine vectorizes the loop, but it also emits runtime alias checks and keeps a fallback scalar loop. The loop is still there.

The `safe_cpp` backend emits:

```llvm
define i32 @sc_scale(i8* noalias nonnull %0,
                     i8* nonnull readonly %1,
                     i32 %2)
```

Compiling that IR with the same optimizer, LLVM collapses the function to:

```asm
movl (%rdi), %eax
testl %edx, %edx
jle .LBB0_2
imull (%rsi), %edx
addl %edx, %eax
movl %eax, (%rdi)
retq
```

One multiply-add instead of a loop. The native version isn't "bad"; it's doing the best it can without alias information. The difference is that the borrow checker supplied a fact the C++ type system didn't.

This is also why I'm careful about how I describe the result. It's not a general claim that "safe_cpp is faster than C++." It's a demonstration that a semantic proof can unlock an optimization the native compiler can't prove safe. The measurement is a microbenchmark, and the speedup depends on the loop and the machine. The correctness argument is the part that matters.

## Testing the model, not just the output

A borrow checker is easy to make look convincing on examples and easy to make wrong on the next case. I ended up with three layers of tests.

**MIR and verifier invariants.** These check the internal shape of the IR: terminators, local IDs, statement ordering, and the assumptions the verifier relies on.

**The lifetime corpus.** `tests/lifetime_cases` holds small programs that must be accepted or rejected. The corpus is the executable specification of the borrow rules: disjoint fields, reborrows, moves, drops, returns, two-phase calls, switch and loop control flow, and known conservative rejections.

**IR and executable tests.** The IR test emits LLVM IR, checks for the expected attributes, assembles it with `llvm-as`, and runs the result. The examples test compiles `hello` and `classes` through the backend and compares their exact output. This catches backend regressions a borrow-only test would miss.

My usual loop:

```sh
cmake -S . -B build
cmake --build build -j2

ctest --test-dir build --output-on-failure
```

When a case failed, I tried to reduce it to the smallest program in the lifetime corpus before touching the solver. That habit mattered more than any single bug fix. Most of the semantic changes I made were driven by a two- or three-line program that exposed a wrong assumption.

Some of those bugs were not in the "obvious" borrow rules:

- A returned reference was not tracked as a borrow of its source.
- A two-phase activation was treated as a new loan instead of a continuation, producing false conflicts.
- Constructor calls were lowered through an ordinary call path that did not model field initialization correctly.
- Static methods were accepted even though the model has no receiver to borrow.
- Switch `break` and loop `continue` cleanups were easy to confuse.
- Lowering reference-returning calls required keeping the pointer value, not prematurely treating the return as a loaded scalar.

Each fix became a regression case. The test suite is the memory of the project.

## What this is not

It's tempting to end a project like this with "and now C++ is safe." That would be false.

- It is not full C++. Raw pointers, templates, exceptions, inheritance, virtual calls, containers, and plenty of other constructs are outside the dialect.
- It is not a platform ABI backend. The emitted LLVM IR is self-contained and should not be linked against C++ objects compiled by another compiler.
- It is not a proof for omitted files or external libraries. Closed-world analysis is a deliberate boundary, not a claim about the rest of the program.
- It is not rustc's NLL or Polonius. The region solver is a point-set draft with documented approximations.
- It is single-threaded and has no atomics model.
- It still has conservative rejections. A valid C++ program can be rejected because the checker cannot represent it precisely. That's the right tradeoff here: over-rejection is a usability problem; unsound acceptance is a correctness problem.

The code generator has limits too. It lowers only the accepted MIR subset. It doesn't model drop flags, exceptions, virtual dispatch, raw pointers, arrays, or external calls, because the policy rejects them first. That keeps the backend honest, but it also means the backend proves a point rather than serving as a production compiler.

## What I would do next

If I kept going, I'd work on precision before adding features.

- Field-sensitive definite initialization and move paths, so field moves and field-by-field initialization stop being blanket rejections.
- A more general two-phase borrow model for borrow-producing expressions, not just method receivers.
- Better summaries for external functions, with explicit contracts instead of closed-world rejection.
- More precise handling of temporaries and full-expression drops.
- A real ABI-compatible lowering path, which is a much larger project than the borrow checker itself.
- A stronger region solver, possibly Polonius-style, if the point-set approach stops scaling or starts producing too many false positives.

But the main lesson wouldn't change.

## What I learned

**Write the policy before the checker.** The smallest useful borrow checker is not "Rust's rules applied to C++." It's a precise statement of what the checker models, followed by a refusal to accept anything outside that statement. The pragma, the closed world, and the rejection list are not paperwork. They are the design.

**A small IR is a feature.** Lowering to my own MIR made it possible to verify the representation, write targeted tests, and reason about provenance, loans, and regions without dragging the entire C++ type system into every rule.

**Alias attributes are semantic claims.** `noalias` is not a performance hint you sprinkle on pointers. It's a promise that the pointer doesn't alias another access. The borrow checker is what makes that promise true. If the proof is wrong, the attribute is worse than useless.

**Return position is where naive alias reasoning breaks.** `&mut` parameters can be `noalias`; a returned reference derived from an argument cannot safely be. Rust's caller-side borrow rules and LLVM's return attribute are not the same fact, and conflating them would produce a fast, wrong compiler.

**Regression tests are the specification.** Every time the model changed, a small program in `tests/lifetime_cases` recorded the behavior. That corpus is more valuable than a long design document, because it fails when the model drifts.

**Conservative is a valid answer.** The checker rejects more than it needs to. That's fine. The project's promise is not "accept all valid C++." It's "accept what it can prove, and say why it rejected the rest."

The final result is a small, opinionated tool: a Clang front end, a custom MIR, a point-set borrow checker, and an LLVM backend that turns a borrow proof into `noalias` and `readonly`. It's not a replacement for a C++ compiler. It's a demonstration that the most valuable part of a borrow checker is not the syntax, or the diagnostics, or even the solver.

It's the decision to define the world you're checking.
