# genmddj manual (working notes)

User-facing reference, built up as features are confirmed. (Engineering/design detail lives
in the project's internal design notes; this is the "how do I use it" side.)

## Command: `I xy` — Iteration (deterministic variation)

`I` gates the note on/off by **which repeat of the phrase** you're on — no randomness, fully
repeatable. The parameter is an **8-bit mask**: the engine looks at bit `(pass − 1) mod 8` of the
mask, and the note **sounds only if that bit is 1**. So the mask is a little 8-step on/off pattern
that repeats every 8 phrase passes. (`bit 0` = pass 1, `bit 7` = pass 8.)

Needs a **looping** phrase to hear it (a short phrase that repeats, or `H` looping back).

### Handy masks

| Byte | Binary | Sounds on passes (of 8) | Pattern |
|---|---|---|---|
| `FF` | `1111 1111` | 1 2 3 4 5 6 7 8 | always |
| `00` | `0000 0000` | — | never (mute) |
| `55` | `0101 0101` | 1 3 5 7 | every other (odd passes) |
| `AA` | `1010 1010` | 2 4 6 8 | every other (even passes) |
| `0F` | `0000 1111` | 1 2 3 4 | first four of eight |
| `F0` | `1111 0000` | 5 6 7 8 | last four of eight |
| `88` | `1000 1000` | 4 8 | every 4th pass |
| `77` | `0111 0111` | 1 2 3 5 6 7 | all but every 4th |

Tip: pair two notes with complementary masks (`55` / `AA`, or `0F` / `F0`) to call-and-respond
across loops, or to alternate two voices without writing two phrases.

### Sibling — `J xy` (repeat-gated transpose)

`J` uses the **same idea but a 4-bit mask** (the `x` nibble), cycling every **4** passes, and on a
masked pass it transposes the note by the signed `y` nibble (`1–7` up, `8–F` = −8…−1). Nibble
masks: `F` = every pass, `5` = passes 1 & 3, `A` = passes 2 & 4, `8` = pass 4 only, `1` = pass 1
only. (`x=0` = off.) On a KIT it swaps the **sample/pad** instead of pitching — deterministic drum
fills.
