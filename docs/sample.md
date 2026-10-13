# Calculus, at a glance

Marky renders Markdown **with real math**. Inline formulas like $e^{i\pi} + 1 = 0$ or \(\sqrt{a^2 + b^2}\)
sit on the line, and display formulas get a line of their own:

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
\qquad
\sum_{k=1}^{n} k = \frac{n(n+1)}{2}
$$

## Derivatives

\[
f'(x) = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}
\]

| Function | Derivative | Note |
|:---------|:----------:|-----:|
| $x^n$ | $n x^{n-1}$ | power rule |
| $e^{ax}$ | $a e^{ax}$ | |
| $\ln x$ | $\dfrac{1}{x}$ | $x > 0$ |
| $\sin x$ | $\cos x$ | ==remember the sign== |

\begin{align*}
(fg)' &= f'g + fg' & \left(\frac{f}{g}\right)' &= \frac{f'g - fg'}{g^2}
\end{align*}

> [!TIP]
> To differentiate $f(g(x))$, multiply the outer derivative by the inner one:
> $\dfrac{d}{dx} f(g(x)) = f'(g(x))\,g'(x)$.

## Checklist

- [x] Limits and continuity
- [x] Product, quotient and chain rules
- [ ] Integration by parts: $\int u\,dv = uv - \int v\,du$
  1. pick $u$ to simplify when differentiated
  2. pick $dv$ you can integrate

> Mathematics is the art of giving the same name to different things.

```python
from math import exp

def f(x):
    return exp(-x**2)   # $not math$ inside code
```

A matrix and a piecewise function, side by side[^1]:
$$
A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}, \qquad
|x| = \begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}
$$

[^1]: Environments such as `pmatrix`, `cases` and `align*` all work, inside `$$` or on their own.
