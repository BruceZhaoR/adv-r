# (PART) Metaprogramming {-}

# Introduction {#meta  .unnumbered}



\index{non-standard evaluation} 

One of the most intriguing things about R is its capability for __metaprogramming__: the idea that code is itself data, and can be inspected and modified programmatically. This is powerful idea and deeply influences much R code. At a simple level this tooling allows you to write `library(purrr)` instead of `library("purrr")` and enables `plot(x, sin(x))` to label the axes with `x` and `sin(x)`. At a deeper level it allows `y ~ x1 + x2` to represent a model that predicts the value of `y` from `x1` and `x2`. It allows `subset(df, x == y)` to be translated to `df[df$x == df$y, , drop = FALSE]`, and for `dplyr::filter(db, is.na(x))` to generate the SQL `WHERE x IS NULL` when `db` is a remote database table.

Closely related to metaprogramming is __non-standard evalution__, or NSE for short. This a term that's commonly used to describe the behaviour of R functions, but there are two problems with the term that lead me to avoid it. Firstly, NSE is actually a property of an argument (or arguments) of a function, so talking about NSE functions is a little sloppy. Secondly, it's confusing to define something by what it is not (standard), so in this book I'll teach you more precise vocabulary. 
In particular, this book focusses on tidy evaluation, or tidy eval for short. Tidy eval which is made up of three major ideas: quasiquotation, quosures, and data masks. This book focusses on the theroetical side of tidy evaluation, so you can fully understand how it works from the ground up. If you are looking for a practical introduction, I recommend the "tidy evaluation book", <https://tidyeval.tidyverse.org>[^tidyeval-wip].

[^tidyeval-wip]: The tidy evaluation book is a work-in-progress at the time I wrote this chapter, but will hopefully be finished by the time you read it!

Metaprogramming is the hardest topic in this book because it forces you grapple with issues that you haven't thought about before. Don't be surprised if you're frustrated or confused at first; this is a natural part of the process that happens to everyone! 

## Big ideas

But before you dive into details, I wanted to give you an overview of the most important ideas and vocabulary of metaprogramming::

* Code is data; captured code is called an expression.
* Code has a tree-like structure called an abstract syntax tree.
* Expressions can be generated by code.
* Evaluation executes an expression in an environment.
* Evaluation can be customised by modifying or overriding the environment.
* Data masks blur environments and data frames.
* A quosure captures an expression with its environment.

Below, I'll use tools primarily from the rlang package, as it allows you to focus on the big ideas, rather than implementation quirks that arise from R's history. This approach seems backward to some, but it's analogous to learning how to drive an automatic transmission before a manual transmission so you can focus on the big picture before learning the details.


```r
library(rlang)
```


### Code is data

The first big idea is that code is data: you can capture code and compute on it like any other type of data. To compute on code, you first need some way to capture it. The first function that captures code is `rlang::expr()`. You can think of it returning exactly what you pass in:


```r
expr(mean(x, na.rm = TRUE))
#> mean(x, na.rm = TRUE)
expr(10 + 100 + 1000)
#> 10 + 100 + 1000
```

More formally, captured code is called an __expression__. An expression isn't a single type of object, but is a collective term for any of four types (call, symbol, constant, or pairlist), which you'll learn more about in Chapter \@ref(expressions).

`expr()` lets you capture code that you've typed. You need a different tool to capture code passed to a function because `expr()` doesn't work:


```r
capture_it <- function(x) {
  expr(x)
}
capture_it(a + b + c)
#> x
```

Here you need to use a function specifically designed to capture user input in a function argument: `enexpr()`. 


```r
capture_it <- function(x) {
  enexpr(x)
}
capture_it(a + b + c)
#> a + b + c
```

Once you have captured an expression, you can inspect and modify it. Complex expressions behave much like lists. That means you can modify them using `[[` and `$`:


```r
f <- expr(f(x = 1, y = 2))

# Add a new argument
f$z <- 3
f
#> f(x = 1, y = 2, z = 3)

# Or remove an argument:
f[[2]] <- NULL
f
#> f(y = 2, z = 3)
```

Note that the first element of the call is the function to be called, which means the first argument is in the second position. You'll learn about the full details in Section \@ref(calls).

### Code is a tree

To do more complex manipulation with code, you need to fully understand its structure. Behind the scenes, almost every programming language represents code as a tree, often called the __abstract syntax tree__, or AST for short. R is unusual in that you can actually inspect and manipulate this tree.

A very convenient tool for understanding the tree-like structure is `lobstr::ast()`. Given some code, will display the underlying tree structure. Function calls form the branches of the tree, and are shown by rectangles. The leaves of the tree are symbols (like `a`) and constants (like `"b"`).


```r
lobstr::ast(f(a, "b"))
#> █─f 
#> ├─a 
#> └─"b"
```

Nested function calls create more deeply branching trees:


```r
lobstr::ast(f1(f2(a, b), f3(1, f4(2))))
#> █─f1 
#> ├─█─f2 
#> │ ├─a 
#> │ └─b 
#> └─█─f3 
#>   ├─1 
#>   └─█─f4 
#>     └─2
```

Because all function forms in can be written in prefix form (Section \@ref(prefix-form)), every R expression can be displayed in this way:


```r
lobstr::ast(1 + 2 * 3)
#> █─`+` 
#> ├─1 
#> └─█─`*` 
#>   ├─2 
#>   └─3
```

Displaying the code tree in this way provides useful tools for exploring R's grammar, the topic of Section \@ref(grammar).

### Code can generate code

As well as seeing the tree from code typed by a human, you can also use code to create new trees. There are two main tools: `call2()` and unquoting. 

`rlang::call2()` constructs a function call from its components: the function to call, and the arguments to call it with.


```r
call2("f", 1, 2, 3)
#> f(1, 2, 3)
call2("+", 1, call2("*", 2, 3))
#> 1 + 2 * 3
```

This is often convenient to program with, but is a bit clunkly for interactive use. An alternative technique is to build complex code trees by combining simpler code trees with a template. `expr()` and `enexpr()` have built-in support for this idea via `!!` (pronounced bang-bang), the __unquote operator__. 

The precise details are the topic of Chapter \@ref(quasiquotation), but basically `!!x` inserts the code tree stored in `x`. This makes it easy to build complex trees from simple fragments:


```r
xx <- expr(x + x)
yy <- expr(y + y)

expr(!!xx / !!yy)
#> (x + x)/(y + y)
```

Notice that the output preserves the operator precedence so we get `(x + x) / (y + y)` not `x + x / y + y` (i.e. `x + (x / y) + y`). This is important to note, particularly if you've been thinking "wouldn't this be easier to do by pasting strings?".

Unquoting gets even more useful when you wrap it up into a function, first using `enexpr()` to capture the user's expression, then `expr()` and `!!` to create an new expression using a template. The example below shows you might generate an expression that computes the coefficient of variation:


```r
cv <- function(var) {
  var <- enexpr(var)
  expr(mean(!!var) / sd(!!var))
}

cv(x)
#> mean(x)/sd(x)
cv(x + y)
#> mean(x + y)/sd(x + y)
```

Importantly, this works even when given weird variable names:


```r
cv(`)`)
#> mean(`)`)/sd(`)`)
```

Dealing with non-syntactic variable names is another good reason to `paste()` when generating R code. You might think this is an esoteric concern, but not worrying about it when generating SQL code in web applications lead to SQL injection attacks that have collectively cost billions of dollars. 

These techniques become yet more powerful when combined with functional programming. You'll explore these ideas in detail in Section \@ref(quasi-case-studies) but the teaser belows shows how you might generate a complex model specification from simple inputs.


```r
library(purrr)
#> 
#> Attaching package: 'purrr'
#> The following objects are masked from 'package:rlang':
#> 
#>     %@%, %||%, as_function, flatten, flatten_chr, flatten_dbl,
#>     flatten_int, flatten_lgl, invoke, list_along, modify, prepend,
#>     rep_along, splice

poly <- function(n) {
  i <- as.double(seq(2, n))
  xs <- c(1, expr(x), map(i, function(i) expr(I(x^!!i))))
  terms <- reduce(xs, call2, .fn = "+")
  expr(y ~ !!terms)
}
poly(5)
#> y ~ 1 + x + I(x^2) + I(x^3) + I(x^4) + I(x^5)
```

### Evaluation excutes an expression in an environment

Inspecting and modifying code gives you one set of powerful tools. You get another set of powerful tools when you __evaluate__, i.e. execute, an expression. Evaluating an expression requires an environment. This tells R what the symbols (found in the leaves of tree) mean. You'll learn the details of evaluation in Chapter \@ref(evaluation).

The primary tool for evaluating expressions is `base::eval()`, which takes an expression and an environment:


```r
eval(expr(x + y), env(x = 1, y = 10))
#> [1] 11
eval(expr(x + y), env(x = 2, y = 100))
#> [1] 102
```

If you omit the environment, it will use the current environment. Here that's the global environment:


```r
x <- 10
y <- 100
eval(expr(x + y))
#> [1] 110
```

One of the big advantages of evaluating code manually is that you can tweak the execution environment. There are two main reaons to do this:

* To temporarily override functions to implement a domain specific language.
* To add a data mask so you can to refer to variables in a data frame as if 
  they are variables in an environment.

### You can override functions to make a DSL

It's fairly straightforward to understand customising the environment with different variable values. It's less obvious that you can also rebind functions to do different things. This is a big idea that we'll come back to in Chapter \@ref(translating), but I wanted to show a small example here. 

The example below evalutes code in a special environment where the basic algebraic operators (`+`, `-`, `*`, `/`) have been overridden to work with string instead of numbers:


```r
string_math <- function(x) {
  e <- env(
    caller_env(),
    `+` = function(x, y) paste0(x, y),
    `*` = function(x, y) strrep(x, y),
    `-` = function(x, y) sub(paste0(y, "$"), "", x),
    `/` = function(x, y) substr(x, 1, nchar(x) / y)
  )

  eval(enexpr(x), e)
}

name <- "Hadley"
string_math("Hi" - "i" + "ello " + name)
#> [1] "Hello Hadley"
string_math("x-" * 3 + "y")
#> [1] "x-x-x-y"
```

dplyr takes this idea to the extreme, running code in an environment that generates SQL for execution in a remote database:


```r
library(dplyr)

con <- DBI::dbConnect(RSQLite::SQLite(), filename = ":memory:")
mtcars_db <- copy_to(con, mtcars)

mtcars_db %>%
  filter(cyl > 2) %>%
  select(mpg:hp) %>%
  head(10) %>%
  show_query()
#> <SQL>
#> SELECT `mpg`, `cyl`, `disp`, `hp`
#> FROM `mtcars`
#> WHERE (`cyl` > 2.0)
#> LIMIT 10

DBI::dbDisconnect(con)
```

### Data masks blur the line between data frames and environments

Rebinding functions is an extremely powerful technique, but it tends to require a lot of investment. A more immediately practical application is modifying evaluation to look for variables in a data frame instead of an environment. This idea powers the base `subset()` and `transform()` functions, as well as many tidyverse functions like `ggplot2::aes()` and `dplyr::mutate()`. It's possible to use `eval()` for this, but there are a few potential pitfalls, so we'll use `rlang::eval_tidy()` instead. 

As well as expression and environment, `eval_tidy()` also takes a __data mask__, which is typically a data frame: 


```r
df <- data.frame(x = 1:5, y = sample(5))
eval_tidy(expr(x + y), df)
#> [1] 2 6 5 9 8
```

Evaluating with a data mask is a useful technique for interactive analysis because it allows you to write `x + y` rather than `df$x + df$y`. However, that convenience comes at a cost: ambiguity. In Section \@ref(pronouns) you'll learn how to deal ambiugity using special `.data` and `.env` pronouns.

We can wrap this pattern up into a function by using `enexpr()`. This gives us a function very similar to `base::with()`:


```r
with2 <- function(df, expr) {
  eval_tidy(enexpr(expr), df)
}

with2(df, x + y)
#> [1] 2 6 5 9 8
```

Unfortunately, however, this function has a subtle bug, and we need a new data structure to deal with it.

### Quosures capture an expression with its environment

To make the problem more obvious, I'm going to modify `with2()`:


```r
with2 <- function(df, expr) {
  a <- 1000
  eval_tidy(enexpr(expr), df)
}
```

(The problem occurs without this modification but it's a sublter and creates error messages that are harder to understand.)

We can see the problem if we attempt to use `with2()` mingling a variable from the data frame, and a variable called `a` in the current environment:


```r
df <- data.frame(x = 1:3)
a <- 10
with2(df, x + a)
#> [1] 1001 1002 1003
```

That's because we really want to evaluate the captured expression in the environment where it was written (where `a` is 10), not the environment inside of `with2()` (where `a` is 1000).

Fortunately we call solve this problem by using a new data structure: the __quosure__ which bundles an expression with an environment. `eval_tidy()` knows how to work with quosures so all we need to do is switch out `enexpr()` for `enquo()`:


```r
with2 <- function(df, expr) {
  a <- 1000
  eval_tidy(enquo(expr), df)
}

with2(df, x + a)
#> [1] 11 12 13
```

Whenever you use a data mask, you must always use `enquo()` instead of `enexpr()`. This is the topic of Chapter \@ref(evaluation).

## Overview {-}

In the following chapters, you'll learn about the three pieces that underpin metaprogramming:

* In __Expressions__, Chapter \@ref(expressions), you'll learn that all R code
  forms a tree. You'll learn how to visualise that tree, how the rules of R's
  grammar convert linear sequences of characters into a tree, and how to use
  recursive functions to work with code trees.
  
* In __Quasiquotation__, Chapter \@ref(quasiquotation), you'll learn to use 
  tools from rlang to capture ("quote") unevaluated function arguments. You'll
  also learn about quasiquotation, which provides a set of techniques for
  "unquoting" input that makes it possible to easily generate new trees from 
  code fragments.
  
* In __Evaluation__, Chapter \@ref(evaluation), you'll learn about the inverse 
  of quotation: evaluation. Here you'll learn about an important data structure,
  the __quosure__, which ensures correct evaluation by capturing both the code 
  to evaluate, and the environment in which to evaluate it. This chapter will 
  show you how to put  all the pieces together to understand how NSE in base 
  R works, and how to write your own functions that work like `subset()`.

* Finally, in __Translating R code__, Chapter \@ref(translation), you'll see 
  how to combine first-class environments, lexical scoping, and metaprogramming 
  to translate R code into other languages, namely HTML and LaTeX.

Each chapter follows the same basic structure. You'll get the lay of the land in introduction, then see a motivating example. Next you'll learn the big ideas using functions from the rlang package [@rlang], and then we'll circle back to talk about how those ideas are expressed in base R. 