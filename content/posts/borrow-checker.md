---
title: How I Wrote a Borrow Checker for a Small Subset of C++
date: 2026-11-15
summary: "A closed-world experiment: lower a Clang AST into a small MIR, borrow-check it, and turn the proofs into LLVM noalias and readonly attributes."
tags:
  - compilers
  - c++
  - rust
  - llvm
---

*A closed-world experiment, from Clang AST to MIR to LLVM `noalias`.*

Borrow checking looks like a type system problem until you try to add it to C++. Rust can define aliasing as part of the language. C++ already has pointers, references, `const`, copy constructors, destructors, inheritance, casts, and decades of code that assumes all of them can alias. If I tried to check all of that, I would spend the rest of the project writing special cases and would still not be able to say what “accepted” meant.

So I did not write a borrow checker for C++. I wrote one for a small, opt-in dialect of C++ and made the boundary part of the design.

The project is called `safe_cpp`. A translation unit opts in with:

```cpp
#pragma safe_cpp
```

Every file that belongs to the program must carry the pragma. The checker analyzes the supplied files as one closed world: every called user function must have a body in those files, every type and global must fit the modeled subset, and there must be exactly one zero-argument `int main()`. If something is outside the subset, the checker rejects it before it can report success.

That sounds restrictive, and it is. But it gave me something a general C++ analyzer usually cannot give: a precise definition of what the checker is claiming. A clean result means “this represented program follows my policy,” not “all of C++ is safe.”

The rest of the project followed from that decision.

## The policy is the product

The first version of the checker was mostly a list of things I refused to model.

Raw pointers were out. So were pointer, reference, and array fields; address-taking; member pointers; arrays and subscripting; globals and statics; thread-local storage; virtual methods; inheritance; templates; lambdas; exceptions; indirect calls; manual `new` and `delete`; alias-forging casts; user-defined copy/move operations; and most operator overloading.

A few things were in: scalars, ordinary records, local references, direct calls with visible bodies, branches, loops, field projections, moves, drops, and a small runtime surface for output. Later I added body-defined constructors and member initializer lists because classes were too awkward to demonstrate without them.

The important rule was not the list itself. It was the order of operations:

1. Parse the marked translation units.
2. Lower the supported Clang AST into my own MIR.
3. Reject anything the MIR cannot represent.
4. Verify the MIR.
5. Borrow-check the MIR.
6. Only then report success, print MIR, or lower to LLVM IR.

That ordering is the difference between a checker and a linter. A linter can skip a construct and still print a warning count. A checker that misses a construct can accept a program for the wrong reason. Once the checker says “OK,” the borrow information becomes the justification for optimization attributes later. There is no room for “probably fine.”

The closed-world requirement also removed a huge class of problems. I did not have to model external function bodies, lifetime annotations on declarations, or ABI behavior across unanalyzed code. A call without a body is a rejection, not a trust decision. That is blunt, but it is honest.

## What the checker actually sees

Clang gives me an AST, but the borrow checker does not operate on the AST directly. A visitor lowers the AST into a small control-flow MIR with basic blocks, statements, terminators, local declarations, and drops.

The central pieces are:

- **Place**: a local plus a sequence of projections, such as `x`, `x.field`, or `(*r).field`.
- **Loan**: a borrow created at a particular MIR point, with an origin and a region.
- **Origin**: the place or value a loan came from. This is what later lets me ask whether two references are derived from the same thing.
- **Region**: a set of MIR points at which a loan is live.
- **Local metadata**: type, mutability, initialization state, drop obligation, and, for reference locals, the origin and region they represent.

A reference is not just a value of reference type. In MIR it carries a loan identity. That is what makes it possible to talk about “the borrow of `bank`” rather than “some pointer.”

The type model is deliberately narrow: scalars, records with fields, references, and parameter types. Pointers are rejected by policy. References are first-class values in MIR, but they are still modeled as tracked loans rather than arbitrary addresses.

The MIR is not rustc’s MIR. It is smaller, shaped around what this checker can prove. That was intentional. A smaller IR is easier to verify, easier to test, and much easier to lower to LLVM.

## The borrow rules I implemented

The checker follows an NLL-style model, but it is an ad-hoc point-set implementation, not a full copy of rustc.

Liveness seeds regions. For each local, the checker computes the MIR points where the local is live. A loan’s region starts at its creation point and is constrained by uses, assignments, calls, reborrows, and returns. The solver propagates those constraints to a fixed point.

Then the rules are mostly what you would expect:

- A **shared loan** permits reads, other shared loans, and shared reborrows.
- A **mutable loan** is exclusive. A read, write, move, drop, or overlapping loan while it is live is rejected.
- A loan ends at its last use, not at the end of the block. A write after the last use is accepted; a write before it is rejected.
- A reborrow is allowed, but using the parent while the child is still live is rejected.
- Moving out of a borrowed place, moving while a loan is live, and dropping while a loan is live are rejected.
- Field projections are field-sensitive: mutable loans of disjoint fields are accepted, while a loan of the whole aggregate overlaps its fields.
- Shared references are copyable. Mutable references and non-copyable records are affine.
- A mutable method receiver that returns `*this` returns a borrow of the receiver; later writes through the receiver conflict until that returned reference’s last use.

The part that took the most iteration was not the basic shared/mutable rule. It was making the region solver agree with the call and return behavior I wanted.

## Two-phase borrows, or why `bank.deposit(bank.balance())` should work

Method calls create an awkward ordering problem.

In a call like:

```cpp
bank.deposit(bank.balance());
```

the receiver is reserved before the arguments are evaluated, but the method body does not run until after the arguments are evaluated. During that window, evaluating `bank.balance()` needs shared access to `bank`. The receiver reservation itself is not yet a mutable activation.

The checker models this as a two-phase borrow for mutable method receivers:

- The receiver gets a **reservation** at the call site.
- Shared reads are allowed while the reservation is pending.
- Mutable access and moves are not.
- The reservation **activates** when the call happens.
- The call’s result borrow is treated as a continuation of the activation loan, not a second conflicting loan.

That last point is subtle. If the activation call creates a new unrelated loan, the solver can report a conflict with the reservation that is still live at the activation point. If it treats the activation as a continuation of the same borrow, the two-phase story stays consistent.

I also had to make sure the solver did not accidentally extend the reservation over the whole function. A reservation should not keep a borrow alive past the call just because the region solver found a path through the activation. Fixing that removed a class of false conflicts without making the checker more permissive elsewhere.

Two-phase support is currently limited to mutable method receivers. It is not a general model for every borrow-producing expression. That limitation is documented, and the checker rejects or conservatively rejects the cases it cannot represent.

## Returns are where soundness gets interesting

A function can return a reference. The checker has to know where that reference came from, because the caller’s borrow checking depends on it.

For example:

```cpp
int& first(int& a, int& b) {
    return a;
}
```

The result of `first(x, y)` is a borrow of `x`, not a fresh loan unrelated to the arguments. The checker infers return origins from function bodies and propagates them through the call graph. If several reference parameters can reach the return, it keeps their union.

If a returned reference is not rooted in a parameter, the checker rejects the function. That rules out returning a reference to a local, which would be a dangling reference in the modeled subset.

This matters for LLVM later. A returned reference is not the same as “a pointer that does not alias any argument.” A function like `id(x)` returns `x` itself, so LLVM’s return `noalias` would be a false claim. The correct lowering is to give the return `nonnull` only, and to let the caller’s borrow information handle exclusivity. That distinction saved me from emitting an unsound attribute.

## Drops and moves

Dropping is not just a call to a destructor. It is a use of the place, and it interacts with borrows.

The checker tracks whether a local is uninitialized, initialized, or moved from. Locals are destroyed at scope exit in reverse construction order. Temporaries are destroyed at the end of their full expression, with an approximation: temporary drops are attached per Clang statement, and a temporary bound to a reference is extended to the enclosing block. The approximation can run a drop later than C++ requires, but never earlier. That is documented rather than hidden.

Destructor effects are summarized. A body-defined destructor is analyzed when it is representable; an implicit destructor, or a destructor whose body is missing, falls back to a conservative write of the whole dropped place. A conservative summary can reject valid code, but it does not invent aliasing freedom.

Moves out of projected fields are rejected until field-sensitive move paths exist. A second move in one expression is diagnosed as a double move rather than a generic use-before-initialization. Those diagnostics are part of the model: the checker should say what rule it thinks you broke.

## Building a class example

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

prints:

```text
balance=150 deposits=2 withdrawals=1 got=30 denied=0 counter=1
logger 7 dropped
```

That output is not the interesting part. The interesting part is that the same run produced borrow facts that can justify alias attributes on the generated LLVM IR.

## From proof to performance

The LLVM backend runs only after MIR verification and borrow checking succeed. It lowers the checked MIR subset to a standalone LLVM module. It is not a general C++ ABI backend; record layout is the backend’s own layout, and the module is self-contained. The point is to demonstrate what the borrow proof is worth, not to replace Clang’s code generator.

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

The return case is deliberately conservative. Return `noalias` would say “the result does not alias any argument pointer.” A function that returns a reference derived from its argument violates that claim by construction. Rust’s caller-side NLL makes the caller’s borrow exclusive; LLVM’s return attribute is a different statement about the pointer value itself. They are not interchangeable.

## The optimization that made the proof visible

The clearest demonstration is `examples/safe_cpp_llvm/noalias.cpp`:

```cpp
int scale(int& acc, const int& step, int n) {
    for (int i = 0; i < n; ++i)
        acc += step;
    return acc;
}
```

Native C++ cannot assume `acc` and `step` do not alias. Clang 22 on my machine vectorizes the loop, but it also emits runtime alias checks and keeps a fallback scalar loop. The loop is still there.

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

One multiply-add instead of a loop. The native version is not “bad”; it is doing the best it can without alias information. The difference is that the borrow checker supplied a fact the C++ type system did not.

This is also why I am careful about how I describe the result. It is not a general claim that “safe_cpp is faster than C++.” It is a demonstration that a semantic proof can unlock an optimization the native compiler cannot prove safe. The measurement is a microbenchmark, and the speedup depends on the loop and the machine. The correctness argument is the part that matters.

## Testing the model, not just the output

A borrow checker is easy to make look convincing on examples and easy to make wrong on the next case. I ended up with three layers of tests.

**MIR and verifier invariants.** These tests check the internal shape of the IR: terminators, local IDs, statement ordering, and the assumptions the verifier relies on.

**The lifetime corpus.** `tests/lifetime_cases` contains small programs that must be accepted or rejected. The corpus is the executable specification of the borrow rules: disjoint fields, reborrows, moves, drops, returns, two-phase calls, switch and loop control flow, and known conservative rejections.

**IR and executable tests.** The IR test emits LLVM IR, checks for the expected attributes, assembles it with `llvm-as`, and runs the result. The examples test compiles `hello` and `classes` through the backend and compares their exact output. This catches backend regressions that a borrow-only test would miss.

My usual loop was:

```sh
cmake -S . -B build
cmake --build build -j2

ctest --test-dir build --output-on-failure
```

When a case failed, I tried to reduce it to the smallest program in the lifetime corpus before changing the solver. That habit mattered more than any single bug fix. Most of the semantic changes I made were driven by a two- or three-line program that exposed a wrong assumption.

Some of those bugs were not in the “obvious” borrow rules:

- A returned reference was not tracked as a borrow of its source.
- A two-phase activation was treated as a new loan instead of a continuation, producing false conflicts.
- Constructor calls were lowered through an ordinary call path that did not model field initialization correctly.
- Static methods were being accepted even though the model has no receiver to borrow.
- Switch `break` and loop `continue` cleanups were easy to confuse.
- Lowering reference-returning calls required keeping the pointer value, not prematurely treating the return as a loaded scalar.

Each fix became a regression case. The test suite is the memory of the project.

## What this is not

It is tempting to end a project like this with “and now C++ is safe.” That would be false.

- It is not full C++. Raw pointers, templates, exceptions, inheritance, virtual calls, containers, and many other constructs are outside the dialect.
- It is not a platform ABI backend. The emitted LLVM IR is self-contained and should not be linked against C++ objects compiled by another compiler.
- It is not a proof for omitted files or external libraries. Closed-world analysis is a deliberate boundary, not a claim about the rest of the program.
- It is not rustc’s NLL or Polonius. The region solver is a point-set draft with documented approximations.
- It is single-threaded and has no atomics model.
- It still has conservative rejections. A valid C++ program can be rejected because the checker cannot represent it precisely. That is the correct tradeoff for this project: over-rejection is a usability problem; unsound acceptance is a correctness problem.

The code generator also has limits. It lowers only the accepted MIR subset. It does not model drop flags, exceptions, virtual dispatch, raw pointers, arrays, or external calls because the policy rejects them first. That keeps the backend honest, but it also means the backend proves a point rather than serving as a production compiler.

## What I would do next

If I continued, I would work on precision before adding features.

- Field-sensitive definite initialization and move paths, so field moves and field-by-field initialization stop being blanket rejections.
- A more general two-phase borrow model for borrow-producing expressions, not just method receivers.
- Better summaries for external functions, with explicit contracts instead of closed-world rejection.
- More precise handling of temporaries and full-expression drops.
- A real ABI-compatible lowering path, which is a much larger project than the borrow checker itself.
- A stronger region solver, possibly Polonius-style, if the point-set approach stops scaling or starts producing too many false positives.

But the main lesson would not change.

## What I learned

**Write the policy before the checker.** The smallest useful borrow checker is not “Rust’s rules applied to C++.” It is a precise statement of what the checker models, followed by a refusal to accept anything outside that statement. The pragma, the closed world, and the rejection list are not paperwork. They are the design.

**A small IR is a feature.** Lowering to my own MIR made it possible to verify the representation, write targeted tests, and reason about provenance, loans, and regions without dragging the entire C++ type system into every rule.

**Alias attributes are semantic claims.** `noalias` is not a performance hint you sprinkle on pointers. It is a promise that the pointer does not alias another access. The borrow checker is what makes that promise true. If the proof is wrong, the attribute is worse than useless.

**Return position is where naive alias reasoning breaks.** `&mut` parameters can be `noalias`; a returned reference derived from an argument cannot safely be. Rust’s caller-side borrow rules and LLVM’s return attribute are not the same fact, and conflating them would produce a fast, wrong compiler.

**Regression tests are the specification.** Every time the model changed, a small program in `tests/lifetime_cases` recorded the behavior. That corpus is more valuable than a long design document, because it fails when the model drifts.

**Conservative is a valid answer.** The checker rejects more than it needs to. That is acceptable. The project’s promise is not “accept all valid C++.” It is “accept what it can prove, and say why it rejected the rest.”

The final result is a small, opinionated tool: a Clang front end, a custom MIR, a point-set borrow checker, and an LLVM backend that turns a borrow proof into `noalias` and `readonly`. It is not a replacement for a C++ compiler. It is a demonstration that the most valuable part of a borrow checker is not the syntax, or the diagnostics, or even the solver.

It is the decision to define the world you are checking.
