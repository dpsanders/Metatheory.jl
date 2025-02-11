using Metatheory 
using Metatheory.EGraphs 
using Test

@metatheory_init ()

struct MyExpr
    head::Any
    # NOTE! this will not work, when replacing 
    # with z in the theory defined below, the arg type 
    # will be EGraphs.EClass! Additional manipulation 
    # is needed for custom term types with stricter arg types
    # args::Vector{Union{Int, MyExpr}}
    args::Vector{Union{Int, MyExpr, EClass}}
    # additional metadata
    foo::String
    bar::Vector{Complex}
    baz::Set{Int}
end

import Base.(==)
(==)(a::MyExpr, b::MyExpr) = a.head == b.head && a.args == b.args &&
    a.foo == b.foo && a.bar == b.bar && a.baz == b.baz 

MyExpr(head, args) = MyExpr(head, args, "", Complex[], Set{Int}())
MyExpr(head) = MyExpr(head, [])

# Methods needed by `src/TermInterface.jl`
TermInterface.gethead(e::MyExpr) = e.head
TermInterface.getargs(e::MyExpr) = e.args
TermInterface.istree(e::MyExpr) = true
# NamedTuple
TermInterface.getmetadata(e::MyExpr) = (foo=e.foo, bar=e.bar, baz=e.baz)
TermInterface.preprocess(e::MyExpr) = MyExpr(e.head, e.args, uppercase(e.foo), e.bar, e.baz)

# f(g(2), h(4)) with some metadata in h
hcall = MyExpr(:h, [4], "hello", [2+3im, 4+2im], Set{Int}([4,5,6]))
ex = MyExpr(:f, [MyExpr(:g, [2]), hcall])


# let's create an egraph 
g = EGraph(ex)

# let's create an example theory
t = @theory begin 
    # this way, z will be a regular expr
    # f(g(2), a) => z(a)
    # we can use dynamic rules to construct values of type MyExpr
    f(g(2), a) |> MyExpr(:z, [a])
end

saturate!(g, t; mod=@__MODULE__)

# Define an extraction method dispatching on MyExpr
function EGraphs.extractnode(n::ENode{MyExpr}, extractor::Function)
    (foo, bar, baz) = n.metadata
    # extracted arguments
    ret_args = []

    for a ∈ n.args 
        push!(ret_args, extractor(a))
    end

    return MyExpr(n.head, ret_args, foo, bar, baz)
end

expected = MyExpr(:z, Any[MyExpr(:h, Any[4], "HELLO", Complex[2 + 3im, 4 + 2im], Set([5, 4, 6]))], "", Complex[], Set{Int64}())
@test extract!(g, astsize) == expected
