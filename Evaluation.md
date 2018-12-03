# Evaluation



## Introduction

The user-facing inverse of quotation is unquotation: it gives the _user_ the ability to selectively evaluate parts of an otherwise quoted argument. The developer-facing complement of quotation is evaluation: this gives the _developer_ the ability to evaluate quoted expressions in custom environments to achieve specific goals.

This chapter begins with a discussion of evaluation in its purest form with `rlang::eval_bare()` which evaluates an expression in given environment. We'll then see how these ideas are used to implement a handful of base R functions, and then learn about the similar `base::eval()`.

The meat of the chapter focusses on extensions needed to implement evaluation robustly. There are two big new ideas:

*   We need a new data structure that captures both the expression __and__ the
    environment associated with each function argument. We call this data 
    structure a __quosure__.
    
*   `base::eval()` supports evaluating an expression in the context of a data 
    frame and an environment. We formalise this idea by naming it the
    __data mask__ and introduce the idea of data pronouns to resolve the 
    ambiguity it creates.

Together, quasiquotation, quosures, and data masks form what we call __tidy evaluation__, or tidy eval for short. Tidy eval provides a principled approach to NSE that makes it possible to use such functions both interactively and embedded with other functions. We'll finish off the chapter showing the basic pattern you use to wrap quasiquoting functions, and how you can adapt that pattern to base R NSE functions.

### Outline {-}

### Prerequisites {-}

As well as the ideas in the previous two chapters, environments play a very important role in evaluation, so make sure you're familiar with the basics in Chapter \@ref(environments).


```r
library(rlang)
library(purrr)
#> 
#> Attaching package: 'purrr'
#> The following objects are masked from 'package:rlang':
#> 
#>     %@%, %||%, as_function, flatten, flatten_chr, flatten_dbl,
#>     flatten_int, flatten_lgl, invoke, list_along, modify, prepend,
#>     rep_along, splice
```

## Evaluation basics {#eval}

In the previous chapter, we briefly mentioned `eval()`. Here, however, we're going to start with `rlang::eval_bare()` which is the purest evocation of the idea of evaluation. It has two arguments: `expr` and `env`.

The first argument, `expr`, is an expression to evaluate. This will usually be either a symbol or expression. None of the evaluation functions quote their inputs, so you'll usually use them with `expr()` or similar:


```r
x <- 10
eval_bare(expr(x))
#> [1] 10

y <- 2
eval_bare(expr(x + y))
#> [1] 12
```

All other objects yield themselves when evaluated:


```r
eval_bare(10)
#> [1] 10

f <- function(x) x + 1
eval_bare(f)
#> function(x) x + 1

df <- data.frame(x = 1, y = 2)
eval_bare(df)
#>   x y
#> 1 1 2
```

The second argument, `env`, gives the environment in which the expression should be evaluated, i.e. where should the values of `x`, `y`, and `+` be looked for? By default, this is the current environment, i.e. the calling environment of `eval_bare()`, but you can override it if you want:


```r
eval_bare(expr(x + y), env(x = 1000))
#> [1] 1002
```

Because R looks up functions in the same way as variables, we can also override the meaning of functions. This is a very useful technique if you want to translate R code into something else, as you'll learn about Chapter \@ref(translation).


```r
eval_bare(
  expr(x + y), 
  env(`+` = function(x, y) paste0(x, " + ", y))
)
#> [1] "10 + 2"
```

Note that the first argument to `eval_bare()` (and to `base::eval()`) is evaluated, not quoted. This can lead to confusing results if you forget to quote the input: 


```r
eval_bare(x + y)
#> [1] 12
eval_bare(x + y, env(x = 1000))
#> [1] 12
```

Now that you've seen the basics, let's explore some applications. We'll focus primarily on base R functions that you might have used before; now you can learn how they work. To focus on the underlying principles, we'll extract out their essence, and rewrite to use rlang functions. Once you've seen some applications, we'll circle back and talk more about `base::eval()`.

### Application: `local()`
\index{local()}

Sometimes you want to perform a chunk of calculation that creates a bunch of intermediate variables. The intermediate variables have no long-term use and could be quite large, so you'd rather not keep them around. One approach is to clean up after yourself using `rm()`; another approach is to wrap the code in a function, and just call it once. A more elegant approach is to use `local()`:


```r
# Clean up variables created earlier
rm(x, y)

foo <- local({
  x <- 10
  y <- 200
  x + y
})

foo
#> [1] 210
x
#> Error in eval(expr, envir, enclos):
#>   object 'x' not found
y
#> Error in eval(expr, envir, enclos):
#>   object 'y' not found
```

The essence of `local()` is quite simple. We capture the input expression, and create a new environment in which to evaluate it. This inherits from the caller environment so it can access the current lexical scope. 


```r
local2 <- function(expr) {
  env <- child_env(caller_env())
  eval_bare(enexpr(expr), env)
}

foo <- local2({
  x <- 10
  y <- 200
  x + y
})

foo
#> [1] 210
x
#> Error in eval(expr, envir, enclos):
#>   object 'x' not found
y
#> Error in eval(expr, envir, enclos):
#>   object 'y' not found
```

Understanding how `base::local()` works is harder, as it uses `eval()` and `substitute()` together in rather complicated ways. Figuring out exactly what's going on is good practice if you really want to understand the subtleties of `substitute()` and the base `eval()` functions, so is included in the exercises below.

### Application: `source()`
\index{source()}

We can create a simple version of `source()` by combining `parse_expr()` and `eval_bare()`. We read in the file from disk, use `parse_expr()` to parse the string into a list of expressions, and then use `eval_bare()` to evaluate each component in turn. This version evaluates the code in the caller environment, and invisibly returns the result of the last expression in the file like `source()`. 


```r
source2 <- function(path, env = caller_env()) {
  file <- paste(readLines(path, warn = FALSE), collapse = "\n")
  exprs <- parse_exprs(file)

  res <- NULL
  for (i in seq_along(exprs)) {
    res <- eval_bare(exprs[[i]], env)
  }
  
  invisible(res)
}
```

The real `source()` is considerably more complicated because it can `echo` input and output, and has many other settings that control its behaviour. 

### Gotcha: `function()`

There's one small gotcha that you should be aware of if you're using `eval_bare()` and `expr()` to generate functions:


```r
x <- 10
y <- 20
f <- eval_bare(expr(function(x, y) !!x + !!y))
f
#> function(x, y) !!x + !!y
```

This function doesn't look like it will work, but it does:


```r
f()
#> [1] 30
```

This is because, if available, functions print their `srcref`. The source reference is a base R feature that doesn't know about quasiquotation. To work around this problem, I recommend using `new_function()` as shown in the previous chapter. Alternatively, you can remove the `srcref` attribute:


```r
attr(f, "srcref") <- NULL
f
#> function (x, y) 
#> 10 + 20
```

### Evaluation vs. unquotation

Evaluation provides an alternative to unquoting.

Popularised by data.table [@data.table]

Notice the difference in timing; need to make sure the expression is stored in a variable with a different name to anything in the dataset.

### Base R

The base function equivalent to `eval_bare()` is the two-argument form of `eval()`: `eval(expr, envir)`: 


```r
eval(expr(x + y), env(x = 1000, y = 1))
#> [1] 1001
```

The final argument, `enclos`, provides support for data masks, which you'll learn about in Section \@ref(tidy-evaluation). 

`eval()` is paired with two helper functions: 

* `evalq(x, env)` quotes its first argument, and is hence a shortcut for 
  `eval(quote(x), env)`.

* `eval.parent(expr, n)` is a shortcut for `eval(expr, env = parent.frame(n))`.

In most cases, there is no reason to prefer `rlang::eval_bare()` over `eval()`; I just used it here because it's a more minimal interface.

::: sidebar
**Expression vectors**

`base::eval()` has special behaviour for expression _vectors_, evaluating each component in turn. This makes for a very compact implementation of `source2()` because `base::parse()` also returns an expression object:


```r
source3 <- function(file, env = parent.frame()) {
  lines <- parse(file)
  res <- eval(lines, envir = env)
  invisible(res)
}
```

While `source3()` is considerably more concise than `source2()`, this one use case is the strongest argument for expression objects, and overall we don't believe this one benefit outweighs the cost of introducing a new data structure. That's why this book has relegated expression vectors to a secondary role.
:::

### Exercises

1.  Carefully read the documentation for `source()`. What environment does it
    use by default? What if you supply `local = TRUE`? How do you provide 
    a custom argument?

1.  Predict the results of the following lines of code:

    
    ```r
    eval(quote(eval(quote(eval(quote(2 + 2))))))
    eval(eval(quote(eval(quote(eval(quote(2 + 2)))))))
    quote(eval(quote(eval(quote(eval(quote(2 + 2)))))))
    ```

1.  Write an equivalent to `get()` using `sym()` and `eval_bare()`. Write an
    equivalent to `assign()` using `sym()`, `expr()`, and `eval_bare()`.
    (Don't worry about the multiple ways of choosing an environment that
    `get()` and `assign()` support; assume that the user supplies it 
    explicitly.)
    
    
    ```r
    # name is a string
    get2 <- function(name, env) {}
    assign2 <- function(name, value, env) {}
    ```

1.  Modify `source2()` so it returns the result of _every_ expression,
    not just the last one. Can you eliminate the for loop?

1.  The code generated by `source2()` lacks source references. Read
    the source code for `sys.source()` and the help for `srcfilecopy()`,
    then modify `source2()` to preserve source references. You can
    test your code by sourcing a function that contains a comment. If
    successful, when you look at the function, you'll see the comment and
    not just the source code.

1.  We can make `base::local()` slightly easier to understand by spreading
    out over multiple lines:
    
    
    ```r
    local3 <- function(expr, envir = new.env()) {
      call <- substitute(eval(quote(expr), envir))
      eval(call, envir = parent.frame())
    }
    ```
    
    Explain how `local()` works in words. (Hint: you might want to `print(call)`
    to help understand what `substitute()` is doing, and read the documentation
    to remind yourself what environment `new.env()` will inherit from.)
    
## Quosures

The simplest form of evaluation combines an expression and an environment. This coupling is so important that it's useful to develop a data structure that can hold both pieces.

To fill this gap, rlang provides the __quosure__, an object that contains an expression and an environment. The name is a portmanteau of quoting and closure, because a quosure both quotes the expression and encloses the environment. Quosures reify the internal promise object (Section \@ref(promise)) into something that you can program with.

In this section, you'll learn how to create and manipulate quosures, and a little about how they are implemented.

### Creating

There are three ways to create quosures:

*   Use `enquo()` and `enquos()` to capture user-supplied expressions, as
    shown above. The vast majority of quosures should be created this way.

    
    ```r
    foo <- function(x) enquo(x)
    foo(a + b)
    #> <quosure>
    #> expr: ^a + b
    #> env:  global
    ```

*   `quo()` and `quos()` exist to match to `expr()` and `exprs()`, but 
    they are included only for the sake of completeness and are needed very
    rarely.

    
    ```r
    quo(x + y + z)
    #> <quosure>
    #> expr: ^x + y + z
    #> env:  global
    ```

*   `new_quosure()` create a quosures from its components: an expression and
    an environment. This is rarely needed in practice, but is useful for
    learning about the system so are over represented in this chapter.

    
    ```r
    new_quosure(expr(x + y), env(x = 1, y = 10))
    #> <quosure>
    #> expr: ^x + y
    #> env:  0x7020488
    ```

### Evaluating

Evaluate a quosure with `eval_tidy()`:


```r
q1 <- new_quosure(expr(x + y), env(x = 1, y = 10))
eval_tidy(q1)
#> [1] 11
```

Compared to `eval_bare()`, which has separate arguments expression and environment, `eval_tidy()` expects them to be bundled into a single object: a quosure. (`eval_tidy()` does have an `env` argument, but it's only needed in very special cases.)

For this simple case, `eval_tidy()` is basically a shortcut for `eval_bare()` using the expression and environment stored in the quosure. But `eval_tidy()` does much more. As well as providing data masks, which you'll learn about shortly, it also allows you to embedded quosures anywhere in the AST. 

Take this example, which inlines two quosures into an expression:


```r
q2 <- new_quosure(expr(x), env(x = 1))
q3 <- new_quosure(expr(x), env(x = 10))

x <- expr(!!q2 + !!q3)
```

It evaluates correctly with `eval_tidy()`:


```r
eval_tidy(x)
#> [1] 11
```

Even though when you print it, you only see the `x`s:


```r
x
#> (~x) + ~x
```

When printing an expression containing quosures, you'll see `~` in front of each quosure. That's because, as you'll learn next, quosures are implemented using formulas. You can get a better display with `rlang::expr_print()` (Section \@ref(non-standard-ast)):


```r
expr_print(x)
#> (^x) + (^x)
```

When you use `expr_print()` in the console, quosures are coloured according to their environment, making it easier to spot when symbols are bound to different variables.

### Dots

Quosures are typically just a convenience: they make code cleaner by bundling together an expression and its environment. They are, however, essential when it comes to working with `...` because it's possible for each argument passed to ... to have a different environment associated with it. In the following example note that both quosures have the same expression, `x`, but a different environment:


```r
f <- function(...) {
  x <- 1
  g(..., f = x)
}
g <- function(...) {
  enquos(...)
}

x <- 0
qs <- f(global = x)
qs
#> <list_of<quosure>>
#> 
#> $global
#> <quosure>
#> expr: ^x
#> env:  global
#> 
#> $f
#> <quosure>
#> expr: ^x
#> env:  0x577ef68
```

That means that when you evaluate them, you get the correct results:


```r
map(qs, eval_tidy)
#> $global
#> [1] 0
#> 
#> $f
#> [1] 1
```

### Under the hood {#quosure-impl}

Quosures were inspired by R's formulas, because formulas capture an expression and an environment:


```r
f <- ~runif(3)
str(f)
#> Class 'formula'  language ~runif(3)
#>   ..- attr(*, ".Environment")=<environment: R_GlobalEnv>
```

Quosures are a subclass of formulas:


```r
q4 <- new_quosure(expr(x + y + z))
class(q4)
#> [1] "quosure" "formula"
```

More precisely, this makes them a call to `~`:


```r
is_call(q4)
#> [1] TRUE

q4[[1]]
#> `~`
q4[[2]]
#> x + y + z
```

With an attribute that stores the environment:


```r
attr(q4, ".environent")
#> NULL
```

If you need to extract the expression or environment, don't rely on the precise details of the implementation. Instead use the `quo_get_` helpers which provide a convenient interface:


```r
quo_get_env(q4)
#> <environment: R_GlobalEnv>
quo_get_expr(q4)
#> x + y + z
```

An early version of tidy evaluation used formulas instead of quosures, as an attractive feature of `~` is that it provides quoting with a single keystroke. Unfortunately, however, there is no clean way to make `~` a quasiquoting function.

### Exercises

1.  Predict what evaluating each of the following quosures will return.

    
    ```r
    q1 <- new_quosure(expr(x), env(x = 1))
    q1
    #> <quosure>
    #> expr: ^x
    #> env:  0x6e741a0
    
    q2 <- new_quosure(expr(x + !!q1), env(x = 10))
    q2
    #> <quosure>
    #> expr: ^x + (^x)
    #> env:  0x704aa60
    
    q3 <- new_quosure(expr(x + !!q2), env(x = 100))
    q3
    #> <quosure>
    #> expr: ^x + (^x + (^x))
    #> env:  0x7309c90
    ```

1.  Write an `enenv()` function that captures the environment associated
    with an argument.
    
## Data masks

So far, you've learned about quosures and `eval_tidy()`. In this section, you'll learn about the __data mask__, a data frame where the evaluated code will look first for variable definitions. The data mask is the key idea that powers base functions like `with()`, `subset()` and `transform()`, and is used throughout the tidyverse in functions like `dplyr::arrange()` and `ggplot2::aes()`.

### Basics

The data mask allows you to mingle variables from an environment and and data frame in a single expression. You supply the data mask as the second argument to `eval_tidy()`:


```r
q1 <- new_quosure(expr(x * y), env(x = 100))
df <- data.frame(y = 1:10)

eval_tidy(q1, df)
#>  [1]  100  200  300  400  500  600  700  800  900 1000
```

But there's a lot of syntax here because we're creating everything from scratch. It's easier to see what's going on if we make a little wrapper. I call this `with2()` because it's equivalent to `base::with()`.


```r
with2 <- function(data, expr) {
  expr <- enquo(expr)
  eval_tidy(expr, data)
}
```

We can now rewrite the code above as below:


```r
x <- 10
with2(df, x * y)
#>  [1]  10  20  30  40  50  60  70  80  90 100
```

`base::eval()` has similar functionality, although it doesn't call it a data mask. Instead you can supply a data frame to the `envir` argument and an environment to the `enclos` argument. That gives the following basic implementation of `with()`:


```r
with <- function(data, expr) {
  expr <- substitute(expr)
  eval(expr, data, enclos = parent.frame())
}
```

Compared to `eval_tidy()` you have to manage the expression and environment separately, and while it's usally correct, there's no guarantee that the `parent.frame()` (aka the caller environment) is the correct environment. 

### Pronouns

The data mask introduces ambiguity. For example, in the following code you can't know whether `x` will come from the data mask or the environment, unless you know what variables are found in `df.`


```r
with2(df, x)
```

That makes code harder to reason about (because you need to know more context), and can introduce bugs. To resolve that issue, the data mask provides two two pronouns: `.data` and `.env`.

* `.data$x` always refers to `x` in the data mask, or dies trying.
* `.env$x`  always refers to `x` in the environment, or dies trying.


```r
x <- 1
df <- data.frame(x = 2)

with2(df, .data$x)
#> [1] 2
with2(df, .env$x)
#> [1] 1
```

You can also subset using `[[`. Otherwise the pronouns are special objects and you shouldn't expect them to behave like data frames or environments.

These also are safe in the sense that they error if the object isn't found:


```r
with2(df, .data$y)
#> Error: Column `y` not found in `.data`
```

Pronouns are particularly important when using tidy evaluation, and we'll come back to them in Section \@ref(pronouns).

### Application: `subset()` {#subset}

We'll explore tidy evaluation in the context of `base::subset()`, because it's a simple yet powerful function that encapsulates one of the central ideas that makes R so elegant for data analysis. If you haven't used it before, `subset()`, like `dplyr::filter()`, provides a convenient way of selecting rows of a data frame. You give it some data, along with an expression that is evaluated in the context of that data. This considerably reduces the number of times you need to type the name of the data frame:


```r
sample_df <- data.frame(a = 1:5, b = 5:1, c = c(5, 3, 1, 4, 1))

# Shorthand for sample_df[sample_df$a >= 4, ]
subset(sample_df, a >= 4)
#>   a b c
#> 4 4 2 4
#> 5 5 1 1

# Shorthand for sample_df[sample_df$b == sample_df$c, ]
subset(sample_df, b == c)
#>   a b c
#> 1 1 5 5
#> 5 5 1 1
```

The core of our version of `subset()`, `subset2()`, is quite simple. It takes two arguments: a data frame, `data`, and an expression, `rows`. We evaluate `rows` using `df` as a data mask, then use the results to subset the data frame with `[`. I've included a very simple check to ensure the result is a logical vector; real code would do more to create an informative error.


```r
subset2 <- function(data, rows) {
  rows <- enquo(rows)
  
  rows_val <- eval_tidy(rows, data)
  stopifnot(is.logical(rows_val))
  
  data[rows_val, , drop = FALSE]
}

subset2(sample_df, b == c)
#>   a b c
#> 1 1 5 5
#> 5 5 1 1
```

### Application: transform

A more complicated situation is `base::transform()` which allows you to add new variables to data frame, evaluating their expressions in the context of the existing variables:


```r
df <- data.frame(x = c(2, 3, 1), y = runif(3))
transform(df, x = -x, y2 = 2 * y)
#>    x     y   y2
#> 1 -2 0.773 1.55
#> 2 -3 0.875 1.75
#> 3 -1 0.175 0.35
```

Implementing `transform2()` is again quite straightforward. We capture the unevalated `...`  with `enquos(...)`, and then evaluate each expression using a for loop. Real code would need to do more error checking, ensure that each input is named, and evaluates to a vector the same length as `data`.


```r
transform2 <- function(.data, ..., .na.last = TRUE) {
  dots <- enquos(...)
  
  for (i in seq_along(dots)) {
    name <- names(dots)[[i]]
    dot <- dots[[i]]
    
    .data[[name]] <- eval_tidy(dot, data = .data)
  }
  
  .data
}

transform2(df, x2 = x * 2, y = -y)
#>   x      y x2
#> 1 2 -0.773  4
#> 2 3 -0.875  6
#> 3 1 -0.175  2
```

Note that I named the first argument `.data`. This avoids problems if the user tried to create a variable called `data`; similar to the reasoning that leads to `map()` having `.x` and `.f` arguments (Section \@ref(argument-names)).

### Application: `select()`

Typically, the data mask will be a data frame. But it's sometimes useful to provide a list filled with more exotic contents. This is basically how the `select` argument `base::subset()` works. It allows you to refer to variables as if they were numbers:


```r
df <- data.frame(a = 1, b = 2, c = 3, d = 4, e = 5)
subset(df, select = b:d)
#>   b c d
#> 1 2 3 4
```

The key idea is to create a named list where each component gives the position of the corresponing variable:


```r
vars <- as.list(set_names(seq_along(df), names(df)))
str(vars)
#> List of 5
#>  $ a: int 1
#>  $ b: int 2
#>  $ c: int 3
#>  $ d: int 4
#>  $ e: int 5
```

Then it's a straight application of `enquo()` and `eval_tidy()`: 


```r
select2 <- function(data, ...) {
  dots <- enquos(...)
  
  vars <- as.list(set_names(seq_along(data), names(data)))
  cols <- unlist(map(dots, eval_tidy, data = vars))
  
  df[, cols, drop = FALSE]
}
select2(df, b:d)
#>   b c d
#> 1 2 3 4
```

`dplyr::select()` takes this idea and runs with it, providing a number of helpers that allow you to select variables based on their names (e.g. `starts_with("x")`, `ends_with("_a"`)).

### Exercises

1.  What the difference between using a for loop and a map function in 
    `transform2()`? Consider `transform2(df, x = x * 2, x = x * 2)`.

1.  Here's an alternative implementation of `subset2()`: 

    
    ```r
    subset3 <- function(data, rows) {
      rows <- enquo(rows)
      eval_tidy(expr(data[!!rows, , drop = FALSE]), data = data)
    }
    
    df <- data.frame(x = 1:3)
    subset3(df, x == 1)
    ```
    
    Compare and constrast `subset3()` to `subset2()`. What are its advantages
    and disadvantages.

1.  The following function implements the basics of `dplyr::arrange()`.   
    Annotate each line with a comment explaining what it does. Can you
    explain why `!!.na.last` is strictly correct, but omitting the `!!`
    is unlikely to cause problems?

    
    ```r
    arrange2 <- function(.df, ..., .na.last = TRUE) {
      args <- enquos(...)
      
      order_call <- expr(order(!!!args, na.last = !!.na.last))
      
      ord <- eval_tidy(order_call, .df)
      stopifnot(length(ord) == nrow(.df))
      
      .df[ord, , drop = FALSE]
    }
    ```

## Using tidy evaluation

While it's useful to understand how `eval_tidy()` works, most of the time you won't call it directly. Instead, in most cases you'll use tidy evaluation indirectly; using a function that uses `eval_tidy()`. Tidy evaluation is infectious: the root always involves a call to `eval_tidy()` but that may be several levels away.

In this section we'll explore how tidy evalution faciliates this division of responsibility, and you'll learn how to create safe and useful wrapper functions.

### Quoting and unquoting

Imagine we have written a function that bootstraps a function:


```r
bootstrap <- function(df, n) {
  idx <- sample(nrow(df), n, replace = TRUE)
  df[idx, , drop = FALSE]
} 
```

And we want to create a new function that allows us to boostrap and subset in a single step. Our naive approach doesn't work:


```r
bootset <- function(df, cond, n = nrow(df)) {
  df2 <- subset2(df, cond)
  bootstrap(df2, n)
}

df <- data.frame(x = c(1, 1, 1, 2, 2), y = 1:5)
bootset(df, x == 1)
#>     x y
#> 1   1 1
#> 2   1 2
#> 3   1 3
#> 1.1 1 1
#> 3.1 1 3
```

`bootset()` doesn't quote any arguments so `cond` is evaluated normally (not in a data mask), and we get an error when it tries to find a binding for  `x`. To fix this problem we need to quote `cond`, and then unquote it when we pass it on ot `subset2()`:


```r
bootset <- function(df, cond, n = nrow(df)) {
  cond <- enquo(cond)
  
  df2 <- subset2(df, !!cond)
  bootstrap(df2, n)
}

bootset(df, x == 1)
#>     x y
#> 1   1 1
#> 2   1 2
#> 3   1 3
#> 1.1 1 1
#> 3.1 1 3
```

This is a very common pattern; whenever you call a quoting function with arguments from the user, you need to quote them yourself and then unquote.

### Handling ambiguity {#pronouns}

In the case above, we needed to think about tidy eval because of quasiquotation. We also need to think tidy evaluation even when the wrapper doesn't need to quote any arguments. Take this wrapper around `subset2()` for example:



```r
threshold_x <- function(df, val) {
  subset2(df, x >= val)
}
```

This function can silently return an incorrect result in two situations:

*   When `x` exists in the calling environment, but not in `df`:
    
    
    ```r
    x <- 10
    no_x <- data.frame(y = 1:3)
    threshold_x(no_x, 2)
    #>   y
    #> 1 1
    #> 2 2
    #> 3 3
    ```

*   When `val` exists in `df`:
   
    
    ```r
    has_val <- data.frame(x = 1:3, val = 9:11)
    threshold_x(has_val, 2)
    #> [1] x   val
    #> <0 rows> (or 0-length row.names)
    ```

These failure modes arise because tidy evaluation is ambiguous: each variable can be found in __either__ the data mask __or__ the environment. To make this function safe we need to remove the ambiguity using the `.data` and `.env` pronouns:


```r
threshold_x <- function(df, val) {
  subset2(df, .data$x >= .env$val)
}

x <- 10
threshold_x(no_x, 2)
#> Error: Column `x` not found in `.data`
threshold_x(has_val, 2)
#>   x val
#> 2 2  10
#> 3 3  11
```

Generally, whenever you use the `.env` pronoun, you can use unquoting instead:


```r
threshold_x <- function(df, val) {
  subset2(df, .data$x >= !!val)
}
```

There are subtle differences in when `val` is evaluated. If you unquote, `val` will be early evaluated by `enquo()`; if you use a pronoun, `val` will be lazily evaluated by `eval_tidy()`. These differences are usually unimportant, so pick the form that looks most natural.

### Quoting and ambiguity

To finish our discussion let's consider the case where we have both quoting and potential ambiguity. Let's generalise `threshold_x()` slightly so that the user can pick the variable used for thresholding? 


```r
threshold_var <- function(df, var, val) {
  var <- as_string(ensym(var))
  subset2(df, .data[[var]] >= !!val)
}

df <- data.frame(x = 1:10)
threshold_var(df, x, 8)
#>     x
#> 8   8
#> 9   9
#> 10 10
```

Note that it is not always the responsibility of the function author to avoid ambiguity. Imagine we generalise further to allow thresholding based on any expression:


```r
threshold_expr <- function(df, expr, val) {
  expr <- enquo(expr)
  subset2(df, !!expr >= !!val)
}
```

It's not possible to evaluate `expr` only the data mask, because the data mask doesn't include any funtions like `+` or `==`. Here, it's the user's responsibility to avoid ambiguity. As a general rule of thumb, as a function author it's your responsibility to avoid ambiguity with any expressions that you create; it's the user's responsibility to avoid ambiguity in expressions that they create.

### Exercises

1.  I've included an alternative implementation of `threshold_var()` below. 
    What makes it different to the approach I used above? What make it harder?

    
    ```r
    threshold_var <- function(df, var, val) {
      var <- ensym(var)
      subset2(df, `$`(.data, !!var) >= !!val)
    }
    ```

## Base evaluation

To understand the benefits of the full tidy evaluation stack, it's worth comparing it to a non-tidy alternative: `subset()`. 

Unfortunately, things are bit more complex if you want to wrap a base R function that quotes an argument. We can no longer rely on tidy evaluation everywhere, because the semantics of NSE functions are not quite rich enough, but we can use it to generate a mostly correct solution. The wrappers that we create can be used interactively, but can not in turn be easily wrapped. This makes them useful for reducing duplication in your analysis code, but not suitable for inclusion in a package.

### `substitute()`

`subset()` is a useful tool, but still simple enough to submit to analysis. 
`substitute()` + `eval()` + `parent.frame()` (or `rlang::caller_env()`)


```r
subset_base <- function(data, rows) {
  rows <- substitute(rows)

  rows_val <- eval(rows, data, parent.frame())
  stopifnot(is.logical(rows_val))
  
  data[rows_val, , drop = FALSE]
}
```

### Drawbacks

The documentation of `subset()` includes the following warning:

> This is a convenience function intended for use interactively. For 
> programming it is better to use the standard subsetting functions like `[`, 
> and in particular the non-standard evaluation of argument `subset` can have 
> unanticipated consequences.

Why is `subset()` dangerous for programming and how does tidy evaluation help us avoid those dangers? First, let's extract out the key parts[^select] of `subset.data.frame()` into a new function, `subset_base()`:

There are three problems with this implementation:

*   `subset()` doesn't support unquoting, so wrapping the function is hard. 
    First, you use `substitute()` to capture the complete expression, then
    you evaluate it. Because `substitute()` doesn't use a syntactic marker for
    unquoting, it is hard to see exactly what's happening here.

    
    ```r
    f1a <- function(df1, expr) {
      call <- substitute(subset_base(df1, expr))
      eval(call, caller_env())
    }
    
    my_df <- data.frame(x = 1:3, y = 3:1)
    f1a(my_df, x == 1)
    #>   x y
    #> 1 1 3
    ```
    
    I think the tidy evaluation equivalent is easier to understand because the
    quoting and unquoting is explicit, and the environment is tied to the 
    expression.
        
    
    ```r
    f1b <- function(df, expr) {
      expr <- enquo(expr)
      subset2(df, !!expr)
    }
    f1b(my_df, x == 1)
    #>   x y
    #> 1 1 3
    ```
    
    This also leads to cleaner tracebacks in the event of an error.
    
*   `base::subset()` always evaluates `rows` in the calling environment, but 
    if `...` has been used, then the expression might need to be evaluated
    elsewhere:

    
    ```r
    f <- function(df, ...) {
      xval <- 3
      subset_base(df, ...)
    }
    
    xval <- 1
    f(my_df, x == xval)
    #>   x y
    #> 3 3 1
    ```
  
    Because `enquo()` captures the environment of the argument as well as its
    expression, this is not a problem with `subset2()`:
  
    
    ```r
    f <- function(df, ...) {
      xval <- 10
      subset_base(df, ...)
    }
    
    xval <- 1
    f(my_df, x == xval)
    #> [1] x y
    #> <0 rows> (or 0-length row.names)
    ```
    
    This may seems like an esoteric concern, but it means that `subset_base()`
    cannot reliably work with functionals like `map()` or `lapply()`:
    
    
    ```r
    local({
      y <- 2
      dfs <- list(data.frame(x = 1:3), data.frame(x = 4:6))
      lapply(dfs, subset_base, x == y)
    })
    #> [[1]]
    #> [1] x
    #> <0 rows> (or 0-length row.names)
    #> 
    #> [[2]]
    #> [1] x
    #> <0 rows> (or 0-length row.names)
    ```

*   Finally, `eval()` doesn't provide any pronouns so there's no way to write
    a safe version of `threshold_x()`.

    
    ```r
    threshold_x <- function(df, val) {
      call <- substitute(subset_base(df1, x > val))
      eval(call, caller_env())
    }
    ```

You might wonder if all this rigamorale is worth it when you can just use `[`. Firstly, it seems unappealing to have functions that can only be used safely in an interactive context. That would mean that every interactive function needs to be paired with function suitable for programming. Secondly, even the simple `subset()` function provides two useful features compared to `[`:

* It sets `drop = FALSE` by default, so it's guaranteed to return a data frame.

* It drops rows where the condition evaluates to `NA`.

That means `subset(df, x == y)` is not equivalent to `df[x == y,]` as you might expect. Instead, it is equivalent to `df[x == y & !is.na(x == y), , drop = FALSE]`: that's a lot more typing!

Real-life alternatives to `subset()`, like `dplyr::filter()`, do even more. For example, `dplyr::filter()` can translate R expressions to SQL so that they can be executed in a database. This makes programming with `filter()` relatively more important (because it does more behind the scenes that you want to take advantage of). Remember we picked `subset()` because it's easy to understand, not because it's particularly featureful.

### Wrapping `subset()` with tidy eval {#base-unquote}

Sometimes it's simpler to create wrappers around base R functions using quasiquotation.


```r
threshold_x <- function(df, val) {
  call <- substitute(subset_base(df1, x > val))
  eval(call, caller_env())
}

threshold_x <- function(df, val) {
  df <- enexpr(df)
  call <- expr(subset(!!df, x >= !!val))
  eval(call, caller_env())
}
```

This code is more verbose, but is a little easier to understand because the unquoting in `expr()` is explict, unlike in `substitute()`. This also allows to inline the value of the `val`, not the expression used to generate it, eliminating one source of ambiguity.

### `match.call()`

Another form which we'll come to back to in the next section (because it poses some specific challenges) uses `match.call()`:


```r
write.csv <- function(...) {
  call <- match.call(expand.dots = TRUE)
  call[[1]] <- quote(write.table)
  call$sep <- ","
  call$dec <- "."
  eval(call, parent.frame())
}
```

### Wrapping modelling functions

Next we'll pivot to consider wrapping modelling functions. This is a common need, and illustrates the spectrum of challenges you'll need to overcome for other base functions. 

Let's start with a very simple wrapper around `lm()`:


```r
lm2 <- function(formula, data) {
  lm(formula, data)
}
```

This wrapper works, but is suboptimal because `lm()` captures its call, and displays it when printing:


```r
lm2(mpg ~ disp, mtcars)
#> 
#> Call:
#> lm(formula = formula, data = data)
#> 
#> Coefficients:
#> (Intercept)         disp  
#>     29.5999      -0.0412
```

This is important because this call is the chief way that you see the model specification when printing the model. To overcome this problem, we need to capture the arguments, create the call to `lm()` using unquoting, then evaluate that call:


```r
lm3 <- function(formula, data) {
  formula <- enexpr(formula)
  data <- enexpr(data)
  
  lm_call <- expr(lm(!!formula, data = !!data))
  expr_print(lm_call)
  eval(lm_call, caller_env())
}
lm3(mpg ~ disp, mtcars)
#> lm(mpg ~ disp, data = mtcars)
#> 
#> Call:
#> lm(formula = mpg ~ disp, data = mtcars)
#> 
#> Coefficients:
#> (Intercept)         disp  
#>     29.5999      -0.0412
```

To make it easier to see what's going on, I'll also print the expression we generate. This will become more useful as the calls get more complicated.

Note that we're evaluating the call in the caller environment. That means we have to also quote data, because if we leave it as is, `data` will not be found. We'll come back to this shortly.

As well as wrapping `lm()` in a way that preserves the call, these wrappers also allow us to use unquoting to generate formulas:


```r
resp <- expr(mpg)
disp1 <- expr(vs)
disp2 <- expr(wt)
lm3(!!resp ~ !!disp1 + !!disp2, mtcars)
#> lm(mpg ~ vs + wt, data = mtcars)
#> 
#> Call:
#> lm(formula = mpg ~ vs + wt, data = mtcars)
#> 
#> Coefficients:
#> (Intercept)           vs           wt  
#>       33.00         3.15        -4.44
```

### The evaluation environment

What if you want to mingle objects supplied by the user with objects that you create in the function?  For example, imagine you want to make an auto-bootstrapping version of `lm()`. You might write it like this:


```r
boot_lm0 <- function(formula, data) {
  formula <- enexpr(formula)
  boot_data <- data[sample(nrow(data), replace = TRUE), , drop = FALSE]
  
  lm_call <- expr(lm(!!formula, data = boot_data))
  expr_print(lm_call)
  eval(lm_call, caller_env())
}

df <- data.frame(x = 1:10, y = 5 + 3 * (1:10) + rnorm(10))
boot_lm0(y ~ x, data = df)
#> lm(y ~ x, data = boot_data)
#> Error in is.data.frame(data):
#>   object 'boot_data' not found
```

Why doesn't this code work? It's because we're evaluating `lm_call` in the caller environment, but `boot_data` exists in the execution environment. We could instead evaluate in the execution environment of `boot_lm0()`, but there's no guarantee that `formula` could be evaluated in that environment.

There are two basic ways to overcome this challenge:

1.  Unquote the data frame into the call. This means that no lookup has
    to occur, but has all the problems of inlining expressions. For modelling 
    functions this means that the captured call is suboptimal:

    
    ```r
    boot_lm1 <- function(formula, data) {
      formula <- enexpr(formula)
      boot_data <- data[sample(nrow(data), replace = TRUE), , drop = FALSE]
      
      lm_call <- expr(lm(!!formula, data = !!boot_data))
      expr_print(lm_call)
      eval(lm_call, caller_env())
    }
    boot_lm1(y ~ x, data = df)$call
    #> lm(y ~ x, data = <data.frame>)
    #> lm(formula = y ~ x, data = list(x = c(2L, 6L, 5L, 8L, 3L, 8L, 
    #> 1L, 4L, 9L, 3L), y = c(13.0650248953592, 22.4779874852545, 18.1369885079317, 
    #> 29.5429963426611, 12.3690105979178, 29.5429963426611, 8.62898204203601, 
    #> 17.5124269498518, 31.0859251727401, 12.3690105979178)))
    ```
    
1.  Alternatively you can create a new environment that inherits from the 
    caller, and you can bind variables that you've created inside the 
    function to that environment.
    
    
    ```r
    boot_lm2 <- function(formula, data) {
      formula <- enexpr(formula)
      boot_data <- data[sample(nrow(data), replace = TRUE), , drop = FALSE]
      
      lm_env <- env(caller_env(), boot_data = boot_data)
      lm_call <- expr(lm(!!formula, data = boot_data))
      expr_print(lm_call)
      eval(lm_call, lm_env)
    }
    boot_lm2(y ~ x, data = df)
    #> lm(y ~ x, data = boot_data)
    #> 
    #> Call:
    #> lm(formula = y ~ x, data = boot_data)
    #> 
    #> Coefficients:
    #> (Intercept)            x  
    #>        5.19         2.92
    ```
    
    This is more work, but gives the cleanest specification.

1.  A third and final option is to continue to evaluate in the parent
    environment, and do the calculation there too. Note that if you ever
    update this model, the data will resample; this feels like an undesirable
    property to me.
    
    
    ```r
    boot_lm2 <- function(formula, data) {
      formula <- enexpr(formula)
      data <- enexpr(data)
      boot_data <- expr(`[`(
        !!data, 
        sample(nrow(!!data), replace = TRUE), , drop = FALSE)
      )
      
      lm_call <- expr(lm(!!formula, data = !!boot_data))
      expr_print(lm_call)
      eval(lm_call, caller_env())
    }
    boot_lm2(y ~ x, data = df)
    #> lm(y ~ x, data = df[sample(nrow(df), replace = TRUE)])
    #> 
    #> Call:
    #> lm(formula = y ~ x, data = df[sample(nrow(df), replace = TRUE), 
    #>     , drop = FALSE])
    #> 
    #> Coefficients:
    #> (Intercept)            x  
    #>        5.87         2.79
    ```


### Quoted arguments

Quoting and unquoting works for all the arguments, even those that are quoted and follow the "standard non-standard" rules of evaluation. This includes the `subset` argument which allows you fit a model to only a subset of the data:


```r
lm4 <- function(formula, data, subset = NULL) {
  formula <- enexpr(formula)
  data <- enexpr(data)
  subset <- enexpr(subset)
  
  lm_call <- expr(lm(!!formula, data = !!data, subset = !!subset))
  expr_print(lm_call)
  eval(lm_call, caller_env())
}
coef(lm4(mpg ~ disp, mtcars))
#> lm(mpg ~ disp, data = mtcars, subset = NULL)
#> (Intercept)        disp 
#>     29.5999     -0.0412
coef(lm4(mpg ~ disp, mtcars, subset = cyl == 4))
#> lm(mpg ~ disp, data = mtcars, subset = cyl == 4)
#> (Intercept)        disp 
#>      40.872      -0.135
```

Note that I've supplied a default argument to `subset`. I think this is good practice because it clearly indicates that `subset` is optional: arguments with no default are usually required. `NULL` has two nice properties here: 

1. `lm()` already knows how to handle `subset = NULL`: it treats it the 
   same way as a missing `subset`.
   
1. `expr(NULL)` is `NULL` which makes it easy to detect in quoted arguments.

However, the current approach has one small downside: `subset = NULL` is shown in the call.


```r
mod <- lm4(mpg ~ disp, mtcars)
#> lm(mpg ~ disp, data = mtcars, subset = NULL)
```

It's possible, if a little more work, to generate a call where `subset` is simply absent. This leads to `lm5()`:


```r
lm5 <- function(formula, data, subset = NULL) {
  formula <- enexpr(formula)
  data <- enexpr(data)
  subset <- enexpr(subset)

  lm_call <- expr(lm(!!formula, data = !!data))
  if (!is.null(subset)) {
    lm_call$subset <- subset
  }
  expr_print(lm_call)
  eval(lm_call, caller_env())
}
mod <- lm5(mpg ~ disp, mtcars)
#> lm(mpg ~ disp, data = mtcars)
```

I probably wouldn't bother with it here, but it's a useful technique to have in your back pocket.

### Making formulas

One final aspect to wrapping modelling functions is generating formulas. You just need to learn about one small wrinkle and then you can use the techniques you learned in [Quotation]. Formulas print the same when evaluated and unevaluated:


```r
y ~ x
#> y ~ x
expr(y ~ x)
#> y ~ x
```

Instead, check the class to make sure you have an actual formula:


```r
class(y ~ x)
#> [1] "formula"
class(expr(y ~ x))
#> [1] "call"
class(eval(expr(y ~ x)))
#> [1] "formula"
```

This is important when you start to mix data and environment variables, which only tends to happen when you start using more complex models:


```r
n <- 3
y ~ ns(x, n)
#> y ~ ns(x, n)
```


Once you understand this, you can generate formulas with unquoting and `reduce()`. Just remember to evaluate the result before returning it. Like in another base NSE wrapper, you should use `caller_env()` as the evaluation environment. 

Here's a simple example that generates a formula by combining a response variable with a set of predictors. 


```r
build_formula <- function(resp, ...) {
  resp <- enexpr(resp)
  preds <- enexprs(...)
  
  pred_sum <- purrr::reduce(preds, ~ expr(!!.x + !!.y))
  eval(expr(!!resp ~ !!pred_sum), caller_env())
}
build_formula(y, a, b, c)
#> y ~ a + b + c
```

### Exercises

1.  Why does this function fail?

    
    ```r
    lm3a <- function(formula, data) {
      formula <- enexpr(formula)
    
      lm_call <- expr(lm(!!formula, data = data))
      eval(lm_call, caller_env())
    }
    lm3(mpg ~ disp, mtcars)$call
    #> lm(mpg ~ disp, data = mtcars)
    #> lm(formula = mpg ~ disp, data = mtcars)
    ```

1.  When model building, typically the response and data are relatively 
    constant while you rapidly experiment with different predictors. Write a
    small wrapper that allows you to reduce duplication in this situation.
    
    
    ```r
    pred_mpg <- function(resp, ...) {
      
    }
    pred_mpg(~ disp)
    pred_mpg(~ I(1 / disp))
    pred_mpg(~ disp * cyl)
    ```
    
1.  Another way to way to write `boot_lm()` would be to include the
    boostrapping expression (`data[sample(nrow(data), replace = TRUE), , drop = FALSE]`) 
    in the data argument. Implement that approach. What are the advantages? 
    What are the disadvantages?

2.  To make these functions somewhat more robust, instead of always using 
    the `caller_env()` we could capture a quosure, and then use its environment.
    However, if there are multiple arguments, they might be associated with
    different environments. Write a function that takes a list of quosures,
    and returns the common environment, if they have one, or otherwise throws 
    an error.

3.  Write a function that takes a data frame and a list of formulas, 
    fitting a linear model with each formula, generating a useful model call.

4.  Create a formula generation function that allows you to optionally 
    supply a transformation function (e.g. `log()`) to the response or
    the predictors.

1.  What does `transform()` do? Read the documentation. How does it work?
    Read the source code for `transform.data.frame()`. What does
    `substitute(list(...))` do? Extract it into it's own function and perform
    experiments to find out.

1.  What does `with()` do? How does it work? Read the source code for
    `with.default()`. What does `within()` do? How does it work? Read the
    source code for `within.data.frame()`. Why is the code so much more
    complex than `with()`?

1.  Implement a version of `within.data.frame()` that uses tidy evaluation.
    Read the documentation and make sure that you understand what `within()`
    does, then read the source code.